#!/usr/bin/env bash
# scripts/simulate-bad-deploy.sh
#
# Demonstrates the automatic rollback mechanism without touching the production
# image or code: temporarily overrides the app's Docker healthcheck to "always
# fail", recreates the container, watches it go unhealthy, then rolls back to
# the known-good image recorded in .deploy-state using the actual rollback logic
# from scripts/deploy.sh.
#
# Trigger this script via .github/workflows/simulate-failure.yml (manual
# workflow_dispatch), or run directly on the VPS:
#     ./scripts/simulate-bad-deploy.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

COMPOSE=(docker compose)
OVERRIDE="docker-compose.sim-fail.yml"
SIM_TIMEOUT="${1:-60}"   # seconds to wait for unhealthy

cya() { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
red() { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; }
grn() { printf '\033[1;32m>> %s\033[0m\n' "$*"; }

# ---- 0. pre-flight checks ----------------------------------------------------
PREV_TAG="$(cat .deploy-state 2>/dev/null || true)"
if [[ -z "$PREV_TAG" ]]; then
  red "No .deploy-state found — nothing to roll back to."
  exit 1
fi
grn "Known-good tag from .deploy-state: $PREV_TAG"

APP_CID="$("${COMPOSE[@]}" ps -q app 2>/dev/null || true)"
CURRENT_IMG="$(docker inspect --format '{{.Config.Image}}' "$APP_CID" 2>/dev/null || echo unknown)"
grn "Current image: $CURRENT_IMG"

# ---- 1. create a healthcheck override that always fails ---------------------
trap 'rm -f "$OVERRIDE"; cya "Override file cleaned up."' EXIT

cat > "$OVERRIDE" <<'OVERRIDE'
services:
  app:
    healthcheck:
      test: ["CMD-SHELL", "exit 1"]
      interval: 5s
      timeout: 3s
      retries: 2
      start_period: 0s
OVERRIDE

# ---- 2. recreate app with the broken healthcheck ----------------------------
cya "Recreating app with a deliberately-failing healthcheck..."
"${COMPOSE[@]}" -f docker-compose.yml -f "$OVERRIDE" \
  up -d --no-deps --force-recreate app < /dev/null

# ---- 3. wait for the container to be marked unhealthy -----------------------
cya "Waiting up to ${SIM_TIMEOUT}s for app to become unhealthy..."
deadline=$(( $(date +%s) + SIM_TIMEOUT ))
while :; do
  CID="$("${COMPOSE[@]}" ps -q app 2>/dev/null || true)"
  status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-hc{{end}}' "$CID" 2>/dev/null || echo missing)"
  echo "   status: $status"
  [[ "$status" == "unhealthy" ]] && break
  (( $(date +%s) >= deadline )) && { red "Timed out waiting for unhealthy."; exit 1; }
  sleep 3
done
red "App is unhealthy — a real bad deploy would look exactly like this."

# ---- 4. roll back to the known-good tag (same logic as deploy.sh) -----------
cya "Rolling back to $PREV_TAG..."
export IMAGE_TAG="$PREV_TAG"
"${COMPOSE[@]}" pull app < /dev/null
"${COMPOSE[@]}" up -d --no-deps --force-recreate app < /dev/null

# ---- 5. wait for the rollback to go healthy ---------------------------------
cya "Waiting for rollback to become healthy..."
deadline=$(( $(date +%s) + 90 ))
while :; do
  CID="$("${COMPOSE[@]}" ps -q app 2>/dev/null || true)"
  status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$CID" 2>/dev/null || echo missing)"
  echo "   status: $status"
  [[ "$status" == "healthy" ]] && break
  (( $(date +%s) >= deadline )) && { red "Rollback did not become healthy."; exit 1; }
  sleep 3
done
grn "Rollback successful — app is healthy again, serving $PREV_TAG."

# ---- 6. verify --------------------------------------------------------------
ROLLED_IMG="$(docker inspect --format '{{.Config.Image}}' "$("${COMPOSE[@]}" ps -q app)" 2>/dev/null)"
grn "Final image: $ROLLED_IMG"
grn "Simulation complete: break healthcheck → unhealthy → rollback → healthy  ✓"
