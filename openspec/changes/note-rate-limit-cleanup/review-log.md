## proposal Round 1 — 2026-07-09
### 🔴 Outstanding
 - "rolling hour" vs "fixed window" wording contradiction (fixed → "fixed-window hour")
 - job "runs once immediately" before 4h interval was omitted (fixed → added to design commitments)
### 🟡 Addressed
 - "unknown" IP fallback behavior unstated (clarified → shared 20/hr bucket)
 - README scope creep (marked doc-only)
 - migration best-effort seed marking fragile on cycled DBs (acknowledged edge case)

## proposal Round 2 — 2026-07-09
### 🔴 Outstanding
 - (none) → proposal.md frozen
### 🟡 Addressed
 - all 5 round-1 items verified fixed; brief coverage complete (9/9 commitments)

## design Round 1 — 2026-07-09
### 🔴 Outstanding
 - (none) → design.md ready to freeze
### 🟡 Addressed
 - Note.seeded must be added to SELECT/RETURNING column lists (added)
 - 429 body must match frozen proposal: drop `remaining` (dropped)
 - circular import db↔jobs must be noted; helpers as function decls; import at bottom; extensionless (done)
 - confirm per-(seeded,title) ensureSeedNotes predicate is intentional (noted)
 - concurrency justification re-based on single-process single-timer caller (done)
 - setup.sql ON CONFLICT removed (it was a no-op); added bootstrap comment (done)
 - checkRateLimit cold-start rule spelled out (done)
 - XFF parsing specified: split(",")[0].trim() (done)

## design Round 2 — 2026-07-09
### 🔴 Outstanding
 - (none) → design.md frozen
### 🟡 Addressed
 - all 8 round-1 nits verified fixed; no decision-level drift vs frozen proposal

## specs Round 1 — 2026-07-09
### 🔴 Outstanding
 - migration requirement/scenario contradicted frozen proposal (omitted best-effort UPDATE; asserted seeded=false) (fixed)
### 🟡 Addressed
 - notes-api: add globalThis/HMR counter-persistence clause (added)
 - "deletes old notes" GIVEN: include an old seeded note + assert deletion (added)
 - validation-ordering: broaden to title/bad-JSON/non-POST (broadened)
 - add "both welcome notes present" reseed scenario (added)
 - job-trigger: name db.server.ts + liveness guarantee (added)

## specs Round 2 — 2026-07-09
### 🔴 Outstanding
 - (none) → specs frozen
### 🟡 Addressed
 - softened invalid-JSON wording to "appropriate error response" (parse currently throws, not 400)

## tasks Round 1 — 2026-07-09
### 🔴 Outstanding
 - Task 2 created out-of-scope db/migrations/2025-add-seeded.sql (removed; tasks renumbered)
### 🟡 Addressed
 - Task 10: pin exact 429 message (done)
 - Task 6: inline cold-start/reset + formulas (done)
 - Task 13: add verify checks for db-demo unthrottled, failure isolation, unknown-IP, window reset (done)

## tasks Round 2 — 2026-07-09
### 🔴 Outstanding
 - (none) → tasks frozen; all artifacts frozen, ready to Apply
### 🟡 Addressed
 - Task 13 could also exercise immediate-first-run / one-missing-reseed / user-title-collision (logic pinned in tasks 4/8; verify focuses on outcomes)

## verify — 2026-07-09 (implementation vs proposal)
### Checks run
 - npm run typecheck: PASS (only deprecation warnings)
 - npm run build: PASS (bundler resolves .server.ts split + import cycle)
 - rate-limit logic unit test (checkRateLimit + getClientIp): 11/11 PASS
   (21st denies, remaining=0, retryAfterSec in range, per-IP buckets, window
   reset, XFF[0]/X-Real-IP/unknown parsing)
 - module-load smoke test: PASS — cleanup job boots via db.server import,
   idempotent globalThis guard holds, failure isolation (DB error logged +
   swallowed, no crash)
### Bug found + fixed during verify
 - circular import db.server <-> jobs.server put `pool` in TDZ: the synchronous
   immediate run accessed `pool` before db.server finished initializing ->
   ReferenceError. Fixed by deferring the immediate run to next tick
   (setTimeout 0). Re-verified: runCleanupOnce now reaches the DB (no TDZ).
### Coverage gaps (honest)
 - Could not execute the SQL against a live Postgres (no DB service available in
   this environment). deleteOldNotes / ensureSeedNotes verified by inspection
   (simple, valid SQL) + reach-the-DB smoke test, not by a real query.
 - Full HTTP 429 round-trip not run (requires the server up + DB); the underlying
   rate-limit logic is unit-tested and the wiring is by inspection.
