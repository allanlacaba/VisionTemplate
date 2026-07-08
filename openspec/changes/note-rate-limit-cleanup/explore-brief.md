# Explore Brief — note-rate-limit-cleanup

## Goal
Add IP-based rate limiting to note creation via the JSON API, and a recurring
background job that periodically deletes old notes and re-seeds the welcome
notes. Keep the change small and dependency-free (this is a demo template).

## Locked decisions (from user)
- Rate-limit policy: **20 creations / hour / client IP**, in-memory, fixed window.
- Rate-limit scope: **POST /api/notes only** (the `db-demo.tsx` form action stays unthrottled).
- Cleanup cadence: **every 4 hours**.
- Cleanup target: **delete notes whose `created_at` is older than 4 hours** (all notes, including old seeded ones).
- After cleanup: **re-seed the 2 welcome notes** if absent.

## Alternatives rejected
- **Rate-limit store**: DB-backed counter and Redis rejected — no auth, single-instance demo, zero extra deps desired. Chose in-memory `Map` on `globalThis` (survives Vite HMR, same pattern as the pg pool). Limitation: not shared across multiple processes/instances — documented.
- **Job scheduler**: external cron hitting a protected endpoint, and the `pg_cron` extension, rejected (extra moving parts / extension install). Chose in-process `setInterval` started via a `.server.ts` module side-effect, guarded by `globalThis` to avoid HMR double-start. Caveat: the timer starts on first server-side import (first DB-using request), not at process boot — acceptable for this template, documented.
- **Reseed idempotency**: "always INSERT 2" rejected (accumulates on first run before anything is 4h old). Matching by title rejected (users can create notes titled "Welcome"). Chose a new **`seeded BOOLEAN NOT NULL DEFAULT false`** column; reseed becomes `INSERT ... WHERE NOT EXISTS (SELECT 1 FROM notes WHERE seeded = true)`.
- **Client IP extraction**: trust `X-Forwarded-For` (first hop), then `X-Real-IP`. The app runs behind Caddy/docker, so these are populated. Spoofing trust assumption documented (no trusted-proxy config available in this stack).

## Module responsibilities & data flow
- `app/lib/rate-limit.server.ts` (new): `getClientIp(request)` + `checkRateLimit(key, {limit, windowMs})` → `{ allowed, remaining, retryAfterSec }`. Store on `globalThis.__noteRateLimit`.
- `app/lib/jobs.server.ts` (new): `startCleanupJob()` — idempotent (globalThis guard), `setInterval(4h)`, runs once immediately, calls `deleteOldNotes()` then `ensureSeedNotes()`. Started via top-level import side-effect from `db.server.ts`.
- `app/lib/db.server.ts` (edited): add `deleteOldNotes()` (`DELETE ... WHERE created_at < now() - interval '4 hours'`) and `ensureSeedNotes()` (idempotent insert of the 2 welcome rows). Import `jobs.server.ts` side-effect to boot the timer. `Note` type gains `seeded: boolean`.
- `app/routes/api.notes.ts` (edited): action extracts IP, calls `checkRateLimit`, returns **429** + `Retry-After` + `{ error }` when denied, else proceeds.
- `db/setup.sql` (edited): add `seeded` column; mark the 2 seed rows `seeded = true`. Provide an `ALTER TABLE` migration snippet for existing DBs in the proposal.

## Open questions
None — all resolved by the user. Remaining items are implementation caveats (job start timing, in-memory store not shared across instances, XFF trust) captured in the proposal/design.
