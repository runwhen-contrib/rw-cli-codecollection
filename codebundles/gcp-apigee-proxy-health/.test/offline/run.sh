#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run.sh -- entrypoint for the offline assertion tier.
#
# Needs no credentials, no cloud access and no network: safe to gate every PR.
#
# The check scripts target the Linux/GNU userland of the RunWhen runner image
# (GNU `date -d`, bash 4+ associative arrays). On a non-Linux host this wrapper
# runs the harness in a Debian container so the offline tier exercises the same
# userland as production instead of a lookalike.
#
#   ./run.sh            # auto: native on Linux, docker elsewhere
#   FORCE_DOCKER=1 ./run.sh
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

# Exit code the in-container bootstrap uses to say "I could not assemble the
# toolchain", so the wrapper can try the next image instead of reporting a
# tooling failure as a test failure -- or worse, as a pass.
readonly ENOTOOLS=97

run_in_image() {
    local image="$1"
    docker run --rm \
        -v "$BUNDLE_DIR":/bundle \
        -e ARTIFACT_ROOT=/bundle/.test/offline/.artifacts \
        --entrypoint bash \
        "$image" \
        -c '
            if ! command -v jq >/dev/null 2>&1; then
                # Only some base images need this, and it needs network egress
                # the sandbox may not have.
                apt-get update -qq >/dev/null 2>&1 \
                  && apt-get install -y -qq --no-install-recommends jq >/dev/null 2>&1 \
                  || exit 97
            fi
            exec bash /bundle/.test/offline/harness.sh
        '
}

# codecollection-devtools ships bash 5, jq and GNU coreutils, so it needs no
# network. debian:stable-slim is the fallback and installs jq if it can.
if [ -n "${OFFLINE_TEST_IMAGE:-}" ]; then
    IMAGES=("$OFFLINE_TEST_IMAGE")
else
    IMAGES=(ghcr.io/runwhen-contrib/codecollection-devtools:latest debian:stable-slim)
fi

for image in "${IMAGES[@]}"; do
    echo "Host is $(uname -s); running offline tier in $image for a Linux/GNU userland."
    set +e
    run_in_image "$image"
    rc=$?
    set -e
    if [ "$rc" -ne "$ENOTOOLS" ]; then
        exit "$rc"
    fi
    echo "  $image: could not assemble bash+jq (no network?); trying the next image." >&2
done

echo "ERROR: no usable container image. The offline tier did NOT run -- this is" >&2
echo "       not a pass. Provide an image with bash and jq via OFFLINE_TEST_IMAGE." >&2
exit 1
