#!/usr/bin/env bash
# Phase 5: container registry and the API image.
#
# Creates:
#   - an Azure Container Registry (Basic) with the admin user turned off, so
#     the only ways in are Entra identities with an Azure role
#   - "AcrPull" for the app's managed identity, on this registry only; the
#     Container App pulls with it in phase 6, with no registry password
# Then, with your local Docker:
#   - builds the image from the repo's Dockerfile for linux/amd64
#   - smoke-tests it locally against a throwaway PostgreSQL container: the API
#     must start, create an entry, and list it back
#   - pushes it, tagged with the git commit it was built from
#
# Requirement #3: no registry password exists; you push with your Entra sign-in
#                 (az acr login) and the app pulls with its managed identity.
# Requirement #5: the image that runs in Azure is the one that passed the
#                 smoke test, traceable to a commit.
#
# Tags: <commit> for a clean tree, or <commit>-dirty-<UTC time> if the files
# that go into the image (api/, pyproject.toml, uv.lock, Dockerfile,
# .dockerignore) have uncommitted changes. A clean tag already in the
# registry isn't rebuilt. Set SKIP_SMOKE_TEST=1 to skip the local test.
#
# BUILD_ONLY=1 builds and smoke-tests the image locally and stops there: it
# creates and pushes nothing, and needs only Docker and az login.
#
# Cost: ~$5/month for the registry (Basic, 10 GB storage included).
# Safe to re-run.

# shellcheck source=config.sh
source "$(dirname "$0")/config.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Work from the repo root and pass relative paths: under Git Bash, git and
# docker are Windows programs and MSYS_NO_PATHCONV (config.sh) stops /c/... paths
# from being translated for them.
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Prerequisites
if ! docker info >/dev/null 2>&1; then
  echo "Docker isn't running. Start Docker Desktop (or the Docker daemon) and re-run." >&2
  exit 1
fi
BUILD_ONLY="${BUILD_ONLY:-0}"
if [[ $BUILD_ONLY != 1 ]] && ! az identity show --resource-group "$RG" --name "$APP_IDENTITY" -o none 2>/dev/null; then
  echo "Managed identity ${APP_IDENTITY} not found. Run ./infra/02-secrets.sh first." >&2
  exit 1
fi

GIT_SHA="$(git rev-parse --short=12 HEAD)"
IMAGE_INPUTS=(api pyproject.toml uv.lock Dockerfile .dockerignore)
if [[ -n $(git status --porcelain -- "${IMAGE_INPUTS[@]}") ]]; then
  IMAGE_TAG="${GIT_SHA}-dirty-$(date -u +%Y%m%d%H%M%S)"
else
  IMAGE_TAG="$GIT_SHA"
fi
LOGIN_SERVER="${ACR}.azurecr.io"
IMAGE="${LOGIN_SERVER}/${IMAGE_REPO}:${IMAGE_TAG}"

echo "Registry     : ${ACR} (${ACR_SKU}, admin user off)"
echo "Image        : ${IMAGE} (${IMAGE_PLATFORM})"
[[ $IMAGE_TAG == *-dirty-* ]] && \
  echo "               uncommitted changes in: $(git status --porcelain -- "${IMAGE_INPUTS[@]}" | awk '{print $2}' | paste -sd' ')"
if [[ $BUILD_ONLY == 1 ]]; then
  echo "Mode         : BUILD_ONLY=1, local build and smoke test only; nothing in Azure changes"
else
  echo "Cost         : ~\$5/month for the registry"
  confirm "create the registry in ${RG}, then build, test and push the image"
fi

# Unfinished chapter exercises still build and run; they just aren't done.
# Requirement #5 (CRUD + live AI analysis) needs them finished.
todo_files="$(grep -rl --include='*.py' 'TODO' "$REPO_ROOT/api" 2>/dev/null | sed "s#^${REPO_ROOT}/##" | paste -sd' ' || true)"
if [[ -n $todo_files ]]; then
  echo
  echo "Note: TODOs remain in ${todo_files}."
  echo "      This image will include those unfinished parts. Rebuild after you finish the chapters."
fi

SMOKE_NET="journal-smoke-$$"
SMOKE_PG="journal-smoke-pg-$$"
SMOKE_API="journal-smoke-api-$$"
cleanup() {
  docker rm -f "$SMOKE_API" "$SMOKE_PG" >/dev/null 2>&1 || true
  docker network rm "$SMOKE_NET" >/dev/null 2>&1 || true
}
WORK_TMP="$(mktemp -d)"
trap 'cleanup; rm -rf "$WORK_TMP"' EXIT

# HTTP status of a request; the body lands in $WORK_TMP/body. (Git Bash's curl
# is a Windows program and can't write to /dev/null, hence the real file.)
http() { # <curl args>...
  curl -s -o "$(native_path "$WORK_TMP/body")" -w '%{http_code}' "$@" || true
}

# ---------------------------------------------------------------------------
if [[ $BUILD_ONLY != 1 ]]; then
log "Container registry ${ACR}"
if az acr show --name "$ACR" -o none 2>/dev/null; then
  echo "  exists"
else
  if [[ $(az_tsv acr check-name --name "$ACR" --query nameAvailable) != true ]]; then
    echo "  The name ${ACR} is taken by another registry. Set SUFFIX to a new value, or" >&2
    echo "  ACR=<new-name> (5-50 letters and digits), and re-run." >&2
    exit 1
  fi
  az acr create --resource-group "$RG" --name "$ACR" --location "$LOCATION" \
    --sku "$ACR_SKU" --admin-enabled false --tags "${TAGS[@]}" -o none
  echo "  created"
fi
if [[ $(az_tsv acr show --name "$ACR" --query adminUserEnabled) == true ]]; then
  az acr update --name "$ACR" --admin-enabled false -o none
  echo "  admin user turned off"
fi
ACR_ID="$(az_tsv acr show --name "$ACR" --query id)"

log "Pull access for ${APP_IDENTITY} (this registry only)"
APP_PRINCIPAL_ID="$(az_tsv identity show --resource-group "$RG" --name "$APP_IDENTITY" --query principalId)"
assign_role "$APP_PRINCIPAL_ID" ServicePrincipal AcrPull "$ACR_ID" "$APP_IDENTITY"
fi

# ---------------------------------------------------------------------------
if [[ $BUILD_ONLY != 1 && $IMAGE_TAG != *-dirty-* ]] && \
   az acr repository show --name "$ACR" --image "${IMAGE_REPO}:${IMAGE_TAG}" -o none 2>/dev/null; then
  log "Image ${IMAGE_REPO}:${IMAGE_TAG} is already in the registry; nothing to build"
else
  log "Building ${IMAGE}"
  docker build --platform "$IMAGE_PLATFORM" --pull \
    --label "org.opencontainers.image.revision=${GIT_SHA}" \
    --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    -t "$IMAGE" .

  # -------------------------------------------------------------------------
  if [[ ${SKIP_SMOKE_TEST:-0} == 1 ]]; then
    log "Smoke test skipped (SKIP_SMOKE_TEST=1)"
  else
    log "Smoke test: the image against a throwaway PostgreSQL ${PG_VERSION}"
    # A private Docker network; only the API's port is published, on 127.0.0.1.
    # Trust auth is fine for a container that lives for a minute and is
    # reachable only from the API container.
    docker network create "$SMOKE_NET" >/dev/null
    docker run -d --name "$SMOKE_PG" --network "$SMOKE_NET" \
      -e POSTGRES_HOST_AUTH_METHOD=trust -e POSTGRES_DB="$PG_DATABASE" \
      "postgres:${PG_VERSION}" >/dev/null
    # TCP readiness means the final server is up, not the init-time one.
    for attempt in $(seq 1 60); do
      docker exec "$SMOKE_PG" pg_isready -q -h 127.0.0.1 -U postgres && break
      (( attempt == 60 )) && { echo "  PostgreSQL didn't start" >&2; exit 1; }
      sleep 1
    done
    docker exec -i "$SMOKE_PG" psql -q -h 127.0.0.1 -U postgres -d "$PG_DATABASE" \
      -v ON_ERROR_STOP=1 -f - <"$REPO_ROOT/database_setup.sql" >/dev/null
    echo "  database ready"

    # Placeholder AI settings, as in .env-sample: enough to start, never used.
    docker run -d --name "$SMOKE_API" --network "$SMOKE_NET" -p 127.0.0.1::8000 \
      -e "DATABASE_URL=postgresql://postgres@${SMOKE_PG}:5432/${PG_DATABASE}" \
      -e OPENAI_API_KEY=placeholder -e OPENAI_BASE_URL=https://example.invalid/v1 \
      -e OPENAI_MODEL=placeholder "$IMAGE" >/dev/null
    API_URL="http://$(docker port "$SMOKE_API" 8000/tcp | head -n 1 | tr -d '\r')"

    smoke_fail() {
      echo "  smoke test failed: $1. API container logs:" >&2
      docker logs --tail 40 "$SMOKE_API" 2>&1 | sed 's/^/    /' >&2
      exit 1
    }
    for attempt in $(seq 1 30); do
      [[ $(http "${API_URL}/docs") == 200 ]] && break
      [[ $(docker inspect -f '{{.State.Running}}' "$SMOKE_API") == true ]] || smoke_fail "the API exited"
      (( attempt == 30 )) && smoke_fail "the API didn't answer within 30 seconds"
      sleep 1
    done
    echo "  API started as user '$(docker exec "$SMOKE_API" id -un | tr -d '\r')'"

    status="$(http -X POST "${API_URL}/entries" -H 'Content-Type: application/json' \
      -d '{"work": "phase 5 smoke test", "struggle": "none", "intention": "ship it"}')"
    [[ $status == 201 ]] || smoke_fail "POST /entries returned ${status:-no response}, expected 201"
    echo "  POST /entries: ${status}"
    status="$(http "${API_URL}/entries")"
    if [[ $status != 200 ]] || ! grep -q "phase 5 smoke test" "$WORK_TMP/body"; then
      smoke_fail "GET /entries didn't return the new entry (HTTP ${status:-no response})"
    fi
    echo "  GET /entries: 200, includes the new entry"

    # Nothing secret baked in.
    docker run --rm --entrypoint sh "$IMAGE" -c 'test ! -e /app/.env && test ! -e .env' \
      || smoke_fail "the image contains a .env file"
    echo "  no .env in the image"
    cleanup
  fi

  if [[ $BUILD_ONLY == 1 ]]; then
    log "Built and tested ${IMAGE} locally (BUILD_ONLY=1); nothing was pushed"
    exit 0
  fi

  # -------------------------------------------------------------------------
  log "Pushing ${IMAGE}"
  # Exchanges your Entra sign-in for a short-lived registry token; no password.
  az acr login --name "$ACR" >/dev/null
  docker push "$IMAGE" | tail -n 1
fi

# ---------------------------------------------------------------------------
log "Done"
az acr repository show --name "$ACR" --image "${IMAGE_REPO}:${IMAGE_TAG}" \
  --query "{image:'${IMAGE_REPO}:${IMAGE_TAG}', digest:digest, created:createdTime}" -o json
echo
echo "Next: infra/README.md, 'Verify phase 5'."
