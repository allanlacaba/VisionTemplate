-- Run with: createdb vision_template && psql -d vision_template -f db/setup.sql
CREATE TABLE IF NOT EXISTS notes (
  id SERIAL PRIMARY KEY,
  title TEXT NOT NULL,
  content TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  seeded BOOLEAN NOT NULL DEFAULT false
);

-- NOTE: setup.sql is a one-time schema bootstrap; it is NOT idempotent and will
-- duplicate seed rows if re-run. It only runs on FIRST database init (the
-- docker-entrypoint-initdb.d mount + db_data volume), so an existing database
-- is NOT updated when this file changes. Schema evolution for existing DBs is
-- handled by ensureMigrated() in app/lib/db.server.ts, which runs an idempotent
-- ALTER TABLE ... ADD COLUMN IF NOT EXISTS on app boot. Runtime reseed
-- idempotency is handled by ensureSeedNotes() (keys off the seeded column).
INSERT INTO notes (title, content, seeded) VALUES
  ('Welcome', 'This note was seeded into your local Postgres database.', true),
  ('It works', 'If you can see this on the DB page, Postgres is connected.', true);
