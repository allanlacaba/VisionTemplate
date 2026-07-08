import { deleteOldNotes, ensureSeedNotes } from "./db.server";

export const CLEANUP_INTERVAL_MS = 4 * 60 * 60 * 1000; // 4 hours

export async function runCleanupOnce(): Promise<void> {
  await deleteOldNotes();
  await ensureSeedNotes();
}

type GlobalWithCleanupJob = typeof globalThis & {
  __cleanupJobStarted?: true;
};

function logError(err: unknown): void {
  console.error("[cleanup] job run failed:", err);
}

export function startCleanupJob(): void {
  const g = globalThis as GlobalWithCleanupJob;
  if (g.__cleanupJobStarted) return;
  g.__cleanupJobStarted = true;

  // Run once immediately, then every 4 hours. The immediate run is deferred to
  // the next tick (setTimeout 0) so it executes AFTER db.server.ts finishes
  // initializing the `pool` (the db↔jobs import cycle would otherwise put `pool`
  // in the temporal dead zone during the synchronous boot). Errors are logged
  // and swallowed so a failing run never crashes the process or cancels the
  // interval.
  const immediate = setTimeout(() => {
    runCleanupOnce().catch(logError);
  }, 0);
  immediate.unref?.();
  const handle = setInterval(() => {
    runCleanupOnce().catch(logError);
  }, CLEANUP_INTERVAL_MS);
  handle.unref();
}

// Boot the job when this module is first imported (server-side only via
// .server.ts). db.server.ts imports this module as a side effect.
startCleanupJob();
