import "dotenv/config";
import { Pool } from "pg";

const connectionString =
  process.env.DATABASE_URL ?? "postgresql://localhost:5432/vision_template";

// Reuse a single pool across HMR reloads in dev.
const globalForDb = globalThis as unknown as { __pgPool?: Pool };

export const pool =
  globalForDb.__pgPool ?? new Pool({ connectionString });

if (!globalForDb.__pgPool) {
  globalForDb.__pgPool = pool;
}

export type Note = {
  id: number;
  title: string;
  content: string;
  created_at: string;
  seeded: boolean;
};

// Self-healing schema migration. The `notes.seeded` column was added in a later
// schema version, but the Postgres init script (docker-entrypoint-initdb.d) only
// runs on first DB init, so an existing database may not have the column yet.
// Run this once per process, awaited before every query so the column is
// guaranteed present. Idempotent (ADD COLUMN IF NOT EXISTS is a fast no-op when
// the column already exists). On failure the cached promise is cleared so the
// next call retries instead of being stuck rejected forever.
let migratePromise: Promise<void> | null = null;
function ensureMigrated(): Promise<void> {
  if (!migratePromise) {
    migratePromise = (async () => {
      await pool.query(
        "ALTER TABLE notes ADD COLUMN IF NOT EXISTS seeded BOOLEAN NOT NULL DEFAULT false",
      );
    })().catch((err: unknown) => {
      migratePromise = null;
      throw err;
    });
  }
  return migratePromise;
}

export async function listNotes(): Promise<Note[]> {
  await ensureMigrated();
  const { rows } = await pool.query<Note>(
    "SELECT id, title, content, created_at, seeded FROM notes ORDER BY created_at DESC, id DESC",
  );
  return rows;
}

export async function createNote(title: string, content: string): Promise<Note> {
  await ensureMigrated();
  const { rows } = await pool.query<Note>(
    "INSERT INTO notes (title, content) VALUES ($1, $2) RETURNING id, title, content, created_at, seeded",
    [title, content],
  );
  return rows[0];
}

export async function deleteNote(id: number): Promise<void> {
  await ensureMigrated();
  await pool.query("DELETE FROM notes WHERE id = $1", [id]);
}

export async function deleteOldNotes(): Promise<void> {
  await ensureMigrated();
  await pool.query(
    "DELETE FROM notes WHERE created_at < now() - interval '4 hours'",
  );
}

const SEED_NOTES: ReadonlyArray<readonly [string, string]> = [
  ["Welcome", "This note was seeded into your local Postgres database."],
  ["It works", "If you can see this on the DB page, Postgres is connected."],
];

export async function ensureSeedNotes(): Promise<void> {
  await ensureMigrated();
  for (const [title, content] of SEED_NOTES) {
    await pool.query(
      `INSERT INTO notes (title, content, seeded)
       SELECT $1, $2, true
       WHERE NOT EXISTS (
         SELECT 1 FROM notes WHERE seeded = true AND title = $1
       )`,
      [title, content],
    );
  }
}

// Boot the recurring cleanup job (idempotent across HMR reloads). Imported at
// the bottom of this file to minimize circular-import exposure; the jobs module
// only invokes deleteOldNotes/ensureSeedNotes asynchronously, after this module
// has finished evaluating.
import "./jobs.server";
