#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run_offline_tests.sh -- entrypoint for the offline assertion tier.
#
# Needs no credentials, no cloud access and no network: safe to gate every PR.
#
# The check scripts target the Linux/GNU userland of the RunWhen runner image
# (GNU `date -d`, bash 4+ associative arrays). On a non-Linux host this wrapper
# runs the harness in a Debian container so the offline tier exercises the same
# userland as production instead of a lookalike.
#
#   ./run_offline_tests.sh            # auto: native on Linux, docker elsewhere
#   FORCE_DOCKER=1 ./run_offline_tests.sh
#
# Exits non-zero if any assertion fails.
# -----------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$HERE/../.." && pwd)"

native_ok() {
    [ "$(uname -s)" = "Linux" ] || return 1
    command -v jq   >/dev/null 2>&1 || return 1
    command -v bash >/dev/null 2>&1 || return 1
    # GNU date is required by the analyze_* scripts.
    date -u -d "@0" "+%s" >/dev/null 2>&1 || return 1
    return 0
}

if [ -z "${FORCE_DOCKER:-}" ] && native_ok; then
    echo "Running offline tier natively (Linux + GNU date + jq detected)."
    exec bash "$HERE/harness.sh"
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: this host is not Linux/GNU and docker is unavailable." >&2
    echo "       The offline tier needs GNU date and bash 4+ to match the runner image." >&2
    exit 1
fi

IMAGE="${OFFLINE_TEST_IMAGE:-debian:stable-slim}"
echo "Host is $(uname -s); running offline tier in $IMAGE for a Linux/GNU userland."

docker run --rm \
    -v "$BUNDLE_DIR":/bundle \
    -e ARTIFACT_ROOT=/bundle/.test/offline/.artifacts \
    "$IMAGE" \
    bash -c '
        set -e
        if ! command -v jq >/dev/null 2>&1; then
            apt-get update -qq >/dev/null
            apt-get install -y -qq --no-install-recommends jq ca-certificates >/dev/null
        fi
        exec bash /bundle/.test/offline/harness.sh
    '
