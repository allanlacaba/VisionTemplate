# Spec Delta — notes-retention

Adds a new `notes-retention` capability: a recurring in-process job that deletes
old notes and re-seeds the welcome notes.

## ADDED Requirements

### Requirement: A background job deletes notes older than 4 hours every 4 hours

A server-side cleanup job SHALL run on an interval of 4 hours. On each run it
SHALL delete every note whose `created_at` is older than 4 hours (`created_at <
now() - interval '4 hours'`), regardless of the `seeded` flag. The job SHALL
also execute once immediately when it starts, before the first 4-hour interval
elapses.

The job SHALL be started via a server-only module side-effect (`*.server.ts`)
imported by `db.server.ts` (so it is live by the time any note is created or
listed), guarded by a `globalThis` flag so that Vite HMR reloads do not start a
second timer. The interval timer SHALL be `.unref()`-ed so it does not keep the
process alive on shutdown. A failing run SHALL be logged and swallowed; it SHALL
NOT throw or cancel the interval.

#### Scenario: deletes old notes
- **GIVEN** notes exist with `created_at` older than 4 hours (including at least
  one with `seeded = true`) and some newer than 4 hours
- **WHEN** the cleanup job runs
- **THEN** only the notes older than 4 hours are deleted, **including the old
  seeded one(s)**
- **AND** the newer notes remain

#### Scenario: immediate first run
- **WHEN** the server module that starts the job is first imported
- **THEN** the cleanup runs once immediately
- **AND** then repeats every 4 hours via `setInterval`

#### Scenario: failure isolation
- **WHEN** a cleanup run raises an error (e.g. DB unavailable)
- **THEN** the error is logged
- **AND** the error does not propagate
- **AND** the 4-hour interval continues to schedule future runs

### Requirement: Welcome notes are re-seeded idempotently after cleanup

After deleting old notes, the job SHALL ensure the two welcome notes ("Welcome"
and "It works") exist with `seeded = true`. For each welcome note, the insert
SHALL be conditional on no row existing with `seeded = true AND title = <that
title>`, so that re-running the job (or re-running after a partial state) never
produces duplicate welcome notes and never overwrites a present one. A
user-created note with the same title but `seeded = false` SHALL NOT block
re-seeding.

#### Scenario: both welcome notes missing
- **GIVEN** the cleanup deleted the old welcome notes (or none exist)
- **WHEN** the re-seed step runs
- **THEN** both welcome notes are inserted with `seeded = true`

#### Scenario: both welcome notes present
- **GIVEN** both "Welcome" and "It works" exist with `seeded = true`
- **WHEN** the re-seed step runs
- **THEN** no rows are inserted
- **AND** neither welcome note is duplicated or overwritten

#### Scenario: one welcome note present
- **GIVEN** only "Welcome" exists with `seeded = true`
- **WHEN** the re-seed step runs
- **THEN** "It works" is inserted with `seeded = true`
- **AND** "Welcome" is not duplicated

#### Scenario: user note shares a welcome title
- **GIVEN** a user note "Welcome" exists with `seeded = false`
- **WHEN** the re-seed step runs
- **THEN** a seeded "Welcome" note is still inserted (`seeded = true`)
- **AND** the user's "Welcome" note is left unchanged

### Requirement: The notes table marks seeded rows

The `notes` table SHALL have a `seeded BOOLEAN NOT NULL DEFAULT false` column.
The `db/setup.sql` bootstrap SHALL create the column and insert the two welcome
rows with `seeded = true`. Existing databases SHALL be migrated with an
idempotent `ALTER TABLE ... ADD COLUMN IF NOT EXISTS seeded ...` **followed by a
best-effort `UPDATE notes SET seeded = true WHERE id IN (SELECT id FROM notes
ORDER BY id LIMIT 2)`** (matches the frozen proposal migration; on a DB that has
already cycled through cleanup runs the two lowest-`id` rows may be user notes,
so this `UPDATE` is best-effort only and does not affect future correctness,
which keys off the `seeded` column). The `Note` type SHALL expose
`seeded: boolean`, populated from the `SELECT` and `RETURNING` column lists.

#### Scenario: fresh database setup
- **WHEN** `db/setup.sql` is run on an empty database
- **THEN** the `notes` table has the `seeded` column
- **AND** the two welcome rows have `seeded = true`

#### Scenario: existing database migration
- **GIVEN** a `notes` table without a `seeded` column, containing existing rows
- **WHEN** the migration (`ALTER ... ADD COLUMN IF NOT EXISTS` + best-effort `UPDATE`) is run
- **THEN** the `seeded` column is added with default `false`
- **AND** the two lowest-`id` rows are marked `seeded = true` (best-effort; may be
  user notes on a DB that has already cycled through cleanup runs)
