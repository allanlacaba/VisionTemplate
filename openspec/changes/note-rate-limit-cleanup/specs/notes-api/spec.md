# Spec Delta — notes-api

Modifies the `notes-api` capability to add IP-based rate limiting on creation.

## MODIFIED Requirements

### Requirement: Note creation via JSON API is rate-limited per IP

The `POST /api/notes` endpoint SHALL enforce a fixed-window rate limit of 20
successful-or-attempted creations per client IP per hour. Reads (`GET /api/notes`)
and the `db-demo.tsx` form action SHALL NOT be rate-limited.

The client IP SHALL be derived from the first hop of the `X-Forwarded-For`
header, falling back to `X-Real-IP`, falling back to the shared key `"unknown"`.

The counter store SHALL live on `globalThis` (a `Map`), so that Vite HMR reloads
in development do not reset the counters.

When the limit is exceeded, the server SHALL respond with HTTP `429`, a
`Retry-After` header (seconds until the current window resets), and a JSON body
of exactly `{ "error": "<message>" }` (no additional fields). The request SHALL
NOT result in a note being created.

#### Scenario: under the limit
- **WHEN** a client IP has made fewer than 20 creations in the current fixed window
- **THEN** `POST /api/notes` with a valid body creates the note and returns `201`
- **AND** the in-process counter for that IP is incremented by one

#### Scenario: at the limit
- **WHEN** a client IP has already made 20 creations in the current fixed window
- **AND** it sends another `POST /api/notes`
- **THEN** the server responds `429`
- **AND** the response includes a `Retry-After` header equal to the seconds
  remaining until the window resets
- **AND** the JSON body is `{ "error": "<message>" }` with no other fields
- **AND** no note is created

#### Scenario: window reset
- **WHEN** the fixed window for an IP has elapsed (>= 3600s since `windowStart`)
- **AND** the IP makes a new request
- **THEN** the counter resets (`count = 0`, `windowStart = now`) before counting
- **AND** the request is allowed (count becomes 1)

#### Scenario: unknown client IP
- **WHEN** the request has neither `X-Forwarded-For` nor `X-Real-IP`
- **THEN** the rate-limit key is `"unknown"`
- **AND** all such clients share a single 20/hour bucket
- **AND** they are neither unlimited nor hard-denied

#### Scenario: rate check ordered after cheap validation
- **WHEN** a `POST /api/notes` has a missing or non-string `title`, OR a body
  that fails JSON parsing, OR is a non-POST method
- **THEN** the server responds with an appropriate error (e.g. `400`/`405`, or a
  thrown parse error handled upstream) **without consuming the IP's rate-limit
  budget** (the rate check runs only after the method/parse/title checks pass)

#### Scenario: rate limit does not apply to other paths
- **WHEN** a note is created via the `db-demo.tsx` form action
- **THEN** no rate-limit counter is consulted or incremented
