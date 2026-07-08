# Tasks — note-rate-limit-cleanup

Frozen baselines: `proposal.md`, `design.md`, `specs/`. Each task is < 2h.

## Schema
- [ ] 1. Add `seeded BOOLEAN NOT NULL DEFAULT false` column to `db/setup.sql`;
      insert the two welcome rows with `seeded = true`. Add the one-time-bootstrap
      comment (setup.sql is NOT idempotent; runtime reseed handles dedup).
      (Existing-DB migration SQL already lives in `proposal.md`; no extra file.)

## DB layer (`app/lib/db.server.ts`)
- [ ] 2. Add `seeded: boolean` to the `Note` type; add `seeded` to the
      `listNotes` `SELECT` list and the `createNote` `RETURNING` list.
- [ ] 3. Add `deleteOldNotes()`: `DELETE FROM notes WHERE created_at < now() -
      interval '4 hours'` (all notes, including seeded). Implement as
      `export async function`.
- [ ] 4. Add `ensureSeedNotes()`: idempotent per-(seeded,title) conditional
      `INSERT ... SELECT ... WHERE NOT EXISTS(...)` for "Welcome" and "It works"
      with `seeded = true`. Implement as `export async function`.

## Rate limiting (`app/lib/rate-limit.server.ts`, new)
- [ ] 5. Implement `getClientIp(request)`: `X-Forwarded-For` first hop via
      `header.split(",")[0]?.trim()`, else `X-Real-IP`, else `"unknown"`.
- [ ] 6. Implement `checkRateLimit(key, {limit, windowMs})` with a
      `globalThis.__noteRateLimit` `Map<string,{count,windowStart}>`:
      cold-start + reset rule — if no entry OR `Date.now() - windowStart >=
      windowMs`, set `windowStart = Date.now()`, `count = 0`; then `count++`;
      `allowed = count <= limit`;
      `retryAfterSec = max(0, ceil((windowStart + windowMs - now)/1000))`;
      `remaining = max(0, limit - count)`. Opportunistic prune of expired entries.

## Background job (`app/lib/jobs.server.ts`, new)
- [ ] 7. Implement `runCleanupOnce()` (`deleteOldNotes()` then
      `ensureSeedNotes()`), wrapped so errors are logged + swallowed, never thrown.
- [ ] 8. Implement `startCleanupJob()` with a `globalThis.__cleanupJobStarted`
      guard: run `runCleanupOnce()` once immediately (fire-and-forget,
      `.catch(log)`), then `setInterval(() => runCleanupOnce().catch(log), 4h)
      .unref()`.
- [ ] 9. Boot the job: add a bottom-of-file `import "./jobs.server";` side effect
       in `app/lib/db.server.ts`; call `startCleanupJob()` at the top level of
       `jobs.server.ts`.

## API wiring (`app/routes/api.notes.ts`)
- [ ] 10. In `action`, after method/JSON/title validation and before
       `createNote`, call `getClientIp` + `checkRateLimit(ip, {limit:20,
       windowMs:3_600_000})`; on deny return `429` with `Retry-After` and body
       exactly `{ "error": "Rate limit exceeded. Try again later." }`
       (no extra fields).

## Docs
- [ ] 11. Add a short "Limits & retention" note to `README.md`: 20 creations /
       hour / IP on `POST /api/notes`; notes older than 4h are deleted every 4h;
       in-memory state not shared across instances; IP via proxy headers.

## Verify
- [ ] 12. `npm run typecheck` passes.
- [ ] 13. Behavioral checks:
       - 21st `POST /api/notes` within the hour → `429` + `Retry-After`, body
         `{ "error": "..." }` only.
       - malformed body / non-POST do NOT consume the IP's rate budget.
       - `db-demo.tsx` form POST still creates a note without consuming the
         JSON-API rate budget (not throttled).
       - after a cleanup run, notes with `created_at < now()-4h` are gone
         (including an old seeded one) and the two welcome notes exist exactly
         once each (`seeded = true`).
       - unknown-IP requests share the single `"unknown"` bucket; a window reset
         allows a fresh request.
       - a failing cleanup run is logged and swallowed; the interval continues.
