#!/usr/bin/env bash
# scripts/deploy.sh
#
# Pulls the prebuilt app image (built & pushed by .github/workflows/ci.yml),
# brings it up, waits for the Docker healthcheck to go healthy, and on failure
# automatically rolls back to the previously recorded known-good image (re-pulled
# from the registry). The Postgres `db` service is never restarted here.
#
# Run on the VPS (invoked by ci.yml's deploy job on every push to main):
#     IMAGE_TAG=<tag from CI> ./scripts/deploy.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# ---- 0. regenerate .env from config + decrypted secrets -------------------
# On the VPS (sops+age installed), config.env provides non-secret values and
# secrets.enc.env is decrypted with the local age private key.  Locally
# (no sops) config.env alone is enough — compose defaults fill the rest.
AGE_KEY="${SOPS_AGE_KEY_FILE:-$ROOT_DIR/keys/age.key}"
: > .env
if command -v sops >/dev/null 2>&1 && [ -f secrets.enc.env ] && [ -f "$AGE_KEY" ]; then
  cat config.env > .env
  SOPS_AGE_KEY_FILE="$AGE_KEY" sops -d secrets.enc.env >> .env || {
    echo "!! sops decrypt failed — check SOPS_AGE_KEY_FILE ($AGE_KEY)" >&2
    exit 1
  }
elif [ -f config.env ]; then
  cp config.env .env
fi

COMPOSE=(docker compose)
APP_SERVICE="app"
STATE_FILE=".deploy-state"          # holds the last known-good image tag
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-90}"   # seconds to wait for the app to become healthy

cya() { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
red() { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; }
grn() { printf '\033[1;32m>> %s\033[0m\n' "$*"; }

# ---- 1. resolve tags ---------------------------------------------------------
NEW_TAG="${IMAGE_TAG:-}"
if [[ -z "$NEW_TAG" ]]; then
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    NEW_TAG="git-$(git rev-parse --short HEAD)"
  else
    NEW_TAG="build-$(date -u +%Y%m%d-%H%M%S)"
  fi
fi
export IMAGE_TAG="$NEW_TAG"

PREV_TAG="$(cat "$STATE_FILE" 2>/dev/null || true)"
[[ -z "$PREV_TAG" ]] && PREV_TAG="(none)"

cya "Deploying app tag: $NEW_TAG   (previous: $PREV_TAG)"

# Make sure db is up (first-time setup, or after a host reboot).
cya "Ensuring db service is up"
"${COMPOSE[@]}" up -d --no-deps db

# ---- 2. pull the prebuilt image for this tag --------------------------------
cya "Pulling ${IMAGE:-ghcr.io/allanlacaba/visiontemplate}:$NEW_TAG"
"${COMPOSE[@]}" pull "$APP_SERVICE"

# ---- 3. launch new app container (db is left untouched) ----------------------
cya "Starting app with the new image"
"${COMPOSE[@]}" up -d --no-deps --force-recreate "$APP_SERVICE"

CONTAINER="$("${COMPOSE[@]}" ps -q "$APP_SERVICE")"
if [[ -z "$CONTAINER" ]]; then
  red "No app container came up — cannot health-check. Aborting."
  exit 1
fi

# ---- 4. wait for the container healthcheck to resolve ------------------------
wait_health() {
  local cid="$1" deadline=$(( $(date +%s) + HEALTH_TIMEOUT )) status=""
  while :; do
    status="$(docker inspect \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' \
      "$cid" 2>/dev/null || echo "missing")"
    case "$status" in
      healthy)  echo healthy; return 0 ;;
      unhealthy) echo unhealthy; return 1 ;;
      *)
        if (( $(date +%s) >= deadline )); then echo timeout; return 1; fi
        sleep 3 ;;
    esac
  done
}

cya "Waiting up to ${HEALTH_TIMEOUT}s for app to become healthy..."
if wait_health "$CONTAINER"; then
  grn "Healthy. Recording $NEW_TAG as known-good."
  printf '%s\n' "$NEW_TAG" > "$STATE_FILE"
  docker image prune -f >/dev/null 2>&1 || true
  grn "Deploy complete: $NEW_TAG"
  exit 0
fi

# ---- 5. rollback -------------------------------------------------------------
red "Deploy FAILED for tag $NEW_TAG."
if [[ "$PREV_TAG" == "(none)" ]]; then
  red "No previous build recorded in $STATE_FILE. App is DOWN."
  red "Recent app logs:"
  "${COMPOSE[@]}" logs --tail=50 "$APP_SERVICE" >&2 || true
  exit 1
fi

cya "Rolling back to previous image: $PREV_TAG"
IMAGE_TAG="$PREV_TAG" "${COMPOSE[@]}" pull "$APP_SERVICE"
IMAGE_TAG="$PREV_TAG" "${COMPOSE[@]}" up -d --no-deps --force-recreate "$APP_SERVICE"

RB_CONTAINER="$("${COMPOSE[@]}" ps -q "$APP_SERVICE")"
if [[ -n "$RB_CONTAINER" ]] && wait_health "$RB_CONTAINER"; then
  grn "Rollback to $PREV_TAG succeeded — app is serving again."
else
  red "Rollback to $PREV_TAG did not become healthy. App may be unhealthy — check logs."
fi

cya "Saving failed build logs to deploy-failure-$NEW_TAG.log"
"${COMPOSE[@]}" logs --tail=200 "$APP_SERVICE" > "deploy-failure-$NEW_TAG.log" 2>&1 || true

exit 1
