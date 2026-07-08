# Proposal — note-rate-limit-cleanup

## Why
The demo exposes an open, unauthenticated note-creation endpoint (`POST /api/notes`)
and a `notes` table that grows without bound. Two problems follow:

1. **Abuse / resource exhaustion** — anyone can hammer `/api/notes` (or the DB)
   and fill the table, degrading the demo for everyone.
2. **Unbounded table growth** — there is no retention; notes accumulate forever,
   which is undesirable for a throwable demo dataset.

This change adds lightweight, dependency-free protections that match the spirit
of the template (small, self-contained, no keys/infra).

## Scope

### In scope
- **Rate limit note creation over the JSON API**: at most **20 creations per
  fixed-window hour per client IP** on `POST /api/notes` (window resets hourly).
  Over the limit → HTTP **429** with a `Retry-After` header and a JSON error
  body. Tracked in-process.
- **Recurring cleanup job**: every **4 hours**, delete all notes whose
  `created_at` is older than 4 hours, then re-seed the two welcome notes if they
  are no longer present.
- **Schema change**: add a `seeded BOOLEAN NOT NULL DEFAULT false` column to
  `notes` so re-seeding is idempotent. Update `db/setup.sql` and provide an
  idempotent migration for already-existing databases.

### Out of scope
- The `db-demo.tsx` form action is **not** rate-limited (per explicit decision).
- No authentication, no users, no per-account limits.
- No distributed/Redis-backed rate limiting — in-memory only.
- No external scheduler (cron, `pg_cron`) — in-process `setInterval`.
- No changes to read paths, listing, or the rest of the API.

## Design commitments (locked)
- Rate limit: **20 / hour / IP**, fixed window, in-memory `Map` on `globalThis`.
- IP source: `X-Forwarded-For` (first hop) → `X-Real-IP` → `"unknown"` fallback.
- 429 response: `{ "error": "<message>" }`, `Retry-After: <seconds to window reset>`.
- Cleanup: `DELETE FROM notes WHERE created_at < now() - interval '4 hours'`,
  then `INSERT` the 2 welcome rows `WHERE NOT EXISTS (... seeded = true ...)`.
- Job lifecycle: on start it executes the cleanup **once immediately**, then
  every 4 hours via `setInterval`. Started via `.server.ts` module side-effect
  (first DB-using request), guarded by `globalThis` against HMR double-start.
  Documented caveat: not at process boot.
- Unknown IP: if neither `X-Forwarded-For` nor `X-Real-IP` is present, the key
  is `"unknown"` — all such clients share a single 20/hr bucket (never unlimited,
  never hard-denied).

## Affected files
- `app/lib/rate-limit.server.ts` (new)
- `app/lib/jobs.server.ts` (new)
- `app/lib/db.server.ts` (edited — new helpers, boot the job, `seeded` on `Note`)
- `app/routes/api.notes.ts` (edited — enforce limit in the action)
- `db/setup.sql` (edited — `seeded` column; seed rows marked)
- `README.md` (edited — doc-only: document the limit + retention behavior)

## Migration (existing DBs)
Run once against an existing `vision_template` database:
```sql
ALTER TABLE notes ADD COLUMN IF NOT EXISTS seeded BOOLEAN NOT NULL DEFAULT false;
UPDATE notes SET seeded = true
 WHERE id IN (SELECT id FROM notes ORDER BY id LIMIT 2);  -- best-effort for existing seeded rows
```
Fresh setups get the correct state directly from `db/setup.sql`.

Caveat: on a DB that has already cycled through cleanup runs, the two lowest-`id`
rows may be user notes rather than welcome notes, so this `UPDATE` is best-effort
only. It only affects migration of an existing DB; it does not affect correctness
of future cleanup/reseed (which keys off the `seeded` column). If exact seed
state matters, manually `DELETE FROM notes WHERE seeded = true;` then run the
`ensureSeedNotes()` insert.

## Known limitations (documented to user)
- Rate-limit state lives in the Node process memory: it is **not shared** across
  multiple app instances/processes (fine for the single-instance demo/deploy).
- The job timer starts on the first server-side import (first DB-using request),
  not at process boot. Under `@react-router/serve` there is no app-level boot hook
  without a custom server entry, which is out of scope.
- Client IP trusts proxy headers (`X-Forwarded-For`); with the included
  Caddy/docker stack these are set correctly. Spoofing is possible if the app is
  exposed directly without the proxy — documented.
