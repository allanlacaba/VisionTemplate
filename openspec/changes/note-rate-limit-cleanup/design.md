# Design — note-rate-limit-cleanup

Frozen baseline: `proposal.md`. This design must stay consistent with it.

## Overview
Two small, dependency-free server modules plus targeted edits:

1. A fixed-window IP rate limiter guarding `POST /api/notes`.
2. An in-process recurring cleanup job (4h) that deletes old notes and re-seeds
   the welcome notes, plus a `seeded` column to make re-seeding idempotent.

## Architecture & data flow

```
                 POST /api/notes
                       │
        ┌──────────────▼──────────────┐
        │ api.notes.ts action         │
        │  ip = getClientIp(request)  │
        │  checkRateLimit(ip) ───────►│ rate-limit.server.ts
        │  denied? → 429 + Retry-After│  (globalThis Map, fixed window)
        │  else createNote(...)       │
        └──────────────┬──────────────┘
                       │
   db.server.ts (imported) ──side-effect──► jobs.server.ts.startCleanupJob()
                       │                       │ setInterval(4h) + run once
                       ▼                       ▼
                  pg Pool           deleteOldNotes() → ensureSeedNotes()
```

- The cleanup timer is booted by a top-level **side-effect import** inside
  `db.server.ts` (the module already imported by every notes route). This avoids
  adding a custom server entry while still guaranteeing the job is live by the
  time any note is created/listed.
- Both the rate-limit store and the job-start guard reuse the existing
  `globalThis` pattern (same as the pg `Pool`) so Vite HMR reloads in dev do not
  spawn duplicates or reset counters.

## Component design

### `app/lib/rate-limit.server.ts` (new)
```ts
type RateLimitResult = { allowed: boolean; remaining: number; retryAfterSec: number };

export function getClientIp(request: Request): string;       // XFF[0] → X-Real-IP → "unknown"
export function checkRateLimit(
  key: string,
  opts: { limit: number; windowMs: number },
): RateLimitResult;
```
- `getClientIp`: `X-Forwarded-For` → `header.split(",")[0]?.trim()` (first hop);
  else `X-Real-IP`; else `"unknown"`.
- Store shape on `globalThis.__noteRateLimit`:
  `Map<string, { count: number; windowStart: number }>`.
- Fixed window — cold start + reset rule: **if there is no entry, OR
  `Date.now() - windowStart >= windowMs`**, then set `windowStart = Date.now()`,
  `count = 0`. Then `count++`; `allowed = count <= limit`.
- `retryAfterSec = max(0, ceil((windowStart + windowMs - now)/1000))`.
- `remaining = max(0, limit - count)`.
- Trace: 20th request allowed (`remaining` 0), 21st denied, `retryAfterSec` →
  window end.
- No unbounded growth: opportunistic prune of expired entries on each call
  (best-effort, O(n) over current keys — fine at demo scale). Documented.

### `app/lib/jobs.server.ts` (new)
```ts
export const CLEANUP_INTERVAL_MS = 4 * 60 * 60 * 1000; // 4h
export async function runCleanupOnce(): Promise<void>; // deleteOldNotes + ensureSeedNotes
export function startCleanupJob(): void;               // idempotent (globalThis guard)
```
- `runCleanupOnce`: `await deleteOldNotes(); await ensureSeedNotes();` wrapped in
  try/catch that logs errors but never throws (a failing run must not crash the
  process or cancel the interval).
- `startCleanupJob`: guarded by `globalThis.__cleanupJobStarted`. If not started,
  call `runCleanupOnce()` (fire-and-forget, `.catch(log)`) then
  `setInterval(() => runCleanupOnce().catch(log), CLEANUP_INTERVAL_MS)`. Use
  `.unref()` on the timer so it does not keep the process alive on shutdown.
- No clock drift concerns: deletion keys off `now()` server-side in SQL, not off
  the JS timer.

### `app/lib/db.server.ts` (edited)
- `Note` type gains `seeded: boolean`. **Both** `listNotes` (`SELECT`) and
  `createNote` (`RETURNING`) must add `seeded` to their column lists so the typed
  value is actually populated (otherwise `seeded` would be `undefined` at runtime).
- New helpers (keep as `export async function` declarations — see circular-import
  note below):
  - `deleteOldNotes()`: `DELETE FROM notes WHERE created_at < now() - interval '4 hours'`.
  - `ensureSeedNotes()`: idempotent insert of the two welcome rows.
    ```sql
    INSERT INTO notes (title, content, seeded)
    SELECT $1, $2, true
    WHERE NOT EXISTS (SELECT 1 FROM notes WHERE seeded = true AND title = $1)
    ```
    run for each of the two seed rows (Welcome / It works). **Intentional
    refinement** over the brief's global check: a per-`(seeded, title)` predicate
    correctly re-seeds one missing welcome note when only the other is present,
    and a user note titled "Welcome" (`seeded=false`) won't block re-seeding.
- Top-level side-effect import to boot the job, placed at the **bottom** of the
  file to minimize circular-import exposure:
  ```ts
  import "./jobs.server"; // extensionless, matches codebase convention; starts cleanup timer (idempotent)
  ```
- Circular-import note: `db.server.ts` imports `jobs.server.ts` (side effect),
  which imports `deleteOldNotes`/`ensureSeedNotes` from `db.server.ts`. This is
  safe in ESM because (a) the helpers are hoisted `export async function`
  declarations, and (b) `runCleanupOnce` invokes them only **asynchronously**
  (after `db.server.ts` has finished evaluating). Keep the new helpers as
  function declarations (not `const` arrows) and keep the side-effect import at
  the bottom.

### `app/routes/api.notes.ts` (edited)
- In `action`, before `createNote`:
  ```ts
  const ip = getClientIp(request);
  const rl = checkRateLimit(ip, { limit: 20, windowMs: 60 * 60 * 1000 });
  if (!rl.allowed) {
    return Response.json(
      { error: "Rate limit exceeded. Try again later." },   // body matches frozen proposal (no extra fields)
      { status: 429, headers: { "Retry-After": String(rl.retryAfterSec) } },
    );
  }
  ```
  (`rl.remaining` is always 0 on a denied request, so it is not included in the
  body; it remains available for logging if desired.)
- Validation order: method check → JSON parse → `title` presence → **rate limit**
  → create. (Rate check after cheap validation so malformed requests don't burn
  a stranger's bucket if the IP is shared — e.g. the `"unknown"` bucket. This is
  a deliberate ordering note.)

### `db/setup.sql` (edited)
```sql
CREATE TABLE IF NOT EXISTS notes (
  id SERIAL PRIMARY KEY,
  title TEXT NOT NULL,
  content TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  seeded BOOLEAN NOT NULL DEFAULT false
);
INSERT INTO notes (title, content, seeded) VALUES
  ('Welcome', '...', true),
  ('It works', '...', true);
-- NOTE: setup.sql is one-time schema bootstrap; it is NOT idempotent and will
-- duplicate seed rows if re-run. Runtime reseed idempotency is handled by
-- ensureSeedNotes() (keys off the seeded column), not by this file.
```
- Existing-DB migration SQL is in `proposal.md` (ALTER + best-effort UPDATE).

### `README.md` (edited, doc-only)
Add a short "Limits & retention" note: 20 creations/hour/IP on `POST /api/notes`,
and that notes older than 4 hours are deleted by a background job every 4 hours
(in-memory state, not shared across instances).

## Error handling & edge cases
- `runCleanupOnce` never throws: DB errors are logged and swallowed; the interval
  keeps firing.
- Rate-limit store memory: keys are IPs; for a demo this is bounded enough. An
  opportunistic prune of expired windows on each `checkRateLimit` call keeps it
  tidy (best-effort, O(n) over current keys — fine at demo scale).
- Unknown IP → single shared `"unknown"` bucket (never unlimited, never denied
  outright).
- Concurrency: `DELETE` and `INSERT ... WHERE NOT EXISTS` are individually atomic
  but **not** race-free across two simultaneous transactions (no unique index).
  Safety here rests on the single-process `setInterval` caller — exactly one
  `runCleanupOnce` is ever scheduled at a time, so `ensureSeedNotes` has no
  concurrent invoker. If `ensureSeedNotes` were ever called from another path, a
  partial unique index `CREATE UNIQUE INDEX ... ON notes(title) WHERE seeded = true`
  would be required.

## Non-goals (restated)
No auth, no distributed limiter, no external scheduler, no throttling of the
`db-demo.tsx` form action, no changes to read/list paths.
