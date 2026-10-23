#!/usr/bin/env bash
#
# Copyright (c) 2026 Covalience LLC. All rights reserved.
# Proprietary and confidential. Licensed for execution by authorized licensees
# only, under a separate agreement with Covalience LLC. See LICENSE.
#
# Covalience E2E test runner — the single step a client drops into any Linux CI
# runner (GitHub Actions, GitLab, Bitbucket, Azure Pipelines, …). It needs only
# bash, curl, jq and docker.
#
# It asks the broker for short-lived pull credentials using the client's license
# key, logs in, pulls the client's image, and runs the tests — writing a JUnit
# report to a results folder the CI can publish.
#
# Required environment:
#   COV_BROKER_URL        the broker Function URL
#   COV_LICENSE_KEY       the license key issued to this client
#   TEST_BASE_URL         the application under test
#   COV_ROLE_CREDENTIALS      role_credentials.json content (inline JSON), OR
#   COV_ROLE_CREDENTIALS_FILE path to a role_credentials.json file
#
# Optional environment:
#   COV_TEST_MODE     story | smoke | regression   (default: regression)
#   COV_IMAGE_TAG     image tag to pull             (default: stable)
#   COV_RESULTS_DIR   where JUnit lands on the host (default: ./e2e-results)
#   COV_TEST_ARGS     extra args passed to the test command
#   TEST_BROWSERS     chromium | firefox | webkit (comma-separated)
set -euo pipefail

# ---- inputs ----------------------------------------------------------------
: "${COV_BROKER_URL:?set COV_BROKER_URL (the broker Function URL)}"
: "${COV_LICENSE_KEY:?set COV_LICENSE_KEY}"
: "${TEST_BASE_URL:?set TEST_BASE_URL (the application under test)}"

IMAGE_TAG="${COV_IMAGE_TAG:-stable}"
TEST_MODE="${COV_TEST_MODE:-regression}"
RESULTS_DIR="${COV_RESULTS_DIR:-$PWD/e2e-results}"

for bin in curl jq docker; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: missing dependency: $bin" >&2; exit 1; }
done

# role_credentials.json: inline JSON or an existing file.
TMP_FILES=()
if [ -n "${COV_ROLE_CREDENTIALS_FILE:-}" ]; then
  ROLE_CREDS_FILE="$COV_ROLE_CREDENTIALS_FILE"
  [ -f "$ROLE_CREDS_FILE" ] || { echo "ERROR: COV_ROLE_CREDENTIALS_FILE not found: $ROLE_CREDS_FILE" >&2; exit 1; }
elif [ -n "${COV_ROLE_CREDENTIALS:-}" ]; then
  ROLE_CREDS_FILE="$(mktemp)"
  TMP_FILES+=("$ROLE_CREDS_FILE")
  printf '%s' "$COV_ROLE_CREDENTIALS" > "$ROLE_CREDS_FILE"
else
  echo "ERROR: set COV_ROLE_CREDENTIALS (inline JSON) or COV_ROLE_CREDENTIALS_FILE (path)" >&2
  exit 1
fi

REGISTRY=""
cleanup() {
  [ -n "$REGISTRY" ] && docker logout "$REGISTRY" >/dev/null 2>&1 || true
  for f in "${TMP_FILES[@]:-}"; do [ -n "${f:-}" ] && rm -f "$f"; done
}
trap cleanup EXIT

# ---- 1. pull credentials from the broker -----------------------------------
echo "==> Requesting pull credentials from broker"
resp="$(curl -fsS -H "X-License-Key: ${COV_LICENSE_KEY}" "$COV_BROKER_URL")" \
  || { echo "ERROR: broker request failed (check COV_BROKER_URL and that the key is active)" >&2; exit 1; }

REGISTRY="$(jq -re '.registry'   <<<"$resp")"
REPOSITORY="$(jq -re '.repository' <<<"$resp")"
USERNAME="$(jq -re '.username'   <<<"$resp")"
IMAGE="${REGISTRY}/${REPOSITORY}:${IMAGE_TAG}"

# ---- 2. docker login (password via stdin, never printed or stored) ----------
echo "==> Logging in to ${REGISTRY}"
jq -re '.password' <<<"$resp" \
  | docker login --username "$USERNAME" --password-stdin "$REGISTRY" >/dev/null
resp=""   # drop the credentials from memory once used

# ---- 3. pull the image -----------------------------------------------------
echo "==> Pulling ${IMAGE}"
docker pull "$IMAGE"

# ---- 4. run the tests ------------------------------------------------------
case "$TEST_MODE" in
  story)      CMD=(test       --reporter=junit,list) ;;
  smoke)      CMD=(smoke      --reporter=junit,list) ;;
  regression) CMD=(regression --reporter=junit,list) ;;
  *) echo "ERROR: invalid COV_TEST_MODE: $TEST_MODE (story|smoke|regression)" >&2; exit 1 ;;
esac
if [ -n "${COV_TEST_ARGS:-}" ]; then
  # shellcheck disable=SC2206
  EXTRA=($COV_TEST_ARGS)
  CMD+=("${EXTRA[@]}")
fi

mkdir -p "$RESULTS_DIR"

echo "==> Running tests (mode: ${TEST_MODE})"
set +e
docker run --rm \
  -e CI=true \
  -e HEADLESS=true \
  -e TEST_BASE_URL="$TEST_BASE_URL" \
  ${TEST_BROWSERS:+-e TEST_BROWSERS="$TEST_BROWSERS"} \
  -e PLAYWRIGHT_JUNIT_OUTPUT_NAME=/app/test-output/junit.xml \
  -v "$ROLE_CREDS_FILE":/app/role_credentials.json:ro \
  -v "$RESULTS_DIR":/app/test-output \
  "$IMAGE" "${CMD[@]}"
code=$?
set -e

echo "==> Finished (exit ${code}). JUnit report in ${RESULTS_DIR}/junit.xml"
exit "$code"
