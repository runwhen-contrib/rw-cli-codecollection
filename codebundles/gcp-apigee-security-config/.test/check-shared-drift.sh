#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# check-shared-drift.sh -- fail when a file that is meant to be byte-identical
# across the gcp-apigee-* bundles is not.
#
# SHARED SUBSTRATE. This file is itself in the manifest below, so it too must be
# byte-identical in every bundle.
#
# WHY THIS EXISTS.
#
# A codebundle ships on its own, so the runtime scripts cannot import a library
# from a sibling directory -- shared logic has to be duplicated. The cost of
# that constraint is drift, and this family has already paid it: the bare-array
# /environments response trap was rediscovered and fixed independently three
# times, in three bundles, because nothing compared the three copies.
#
# apigee_prerequisites.sh makes that worse before it makes it better. It is
# ~250 lines of provisioning logic duplicated five ways, and a fix applied to
# one copy is invisible in the other four. Enforced duplication is fine. Silent
# divergence is what hurts, so `task ci` checksums the copies against each other
# and fails on a mismatch, naming the file and the bundles that disagree.
#
# This deliberately does NOT try to merge or copy anything. It reports; a human
# decides which copy is right.
#
# Usage: ./check-shared-drift.sh
# Exit 0 when every copy agrees (or when there are no siblings to compare
# against, e.g. a bundle extracted on its own), 1 on any divergence.
# -----------------------------------------------------------------------------
set -uo pipefail

# Files that must be byte-identical in every gcp-apigee-*/.test/ directory.
# Paths are relative to the .test directory.
SHARED_FILES="
apigee_prerequisites.sh
check-shared-drift.sh
validate-all-tests.sh
"

HERE="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR="$(cd "${HERE}/.." && pwd)"
COLLECTION_DIR="$(cd "${BUNDLE_DIR}/.." && pwd)"
SELF_BUNDLE="$(basename "${BUNDLE_DIR}")"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'

sum() {
    # shasum is present on macOS and in the runner image; sha256sum is not on
    # macOS. Falling back keeps this runnable from a developer laptop.
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

siblings=""
sibling_count=0
for d in "${COLLECTION_DIR}"/gcp-apigee-*/; do
    [ -d "${d}" ] || continue
    name="$(basename "${d}")"
    [ "${name}" = "${SELF_BUNDLE}" ] && continue
    [ -d "${d}.test" ] || continue
    siblings="${siblings} ${name}"
    sibling_count=$((sibling_count + 1))
done

printf '%s== shared-substrate drift%s\n' "${BLUE}" "${NC}"

if [ -z "${siblings}" ]; then
    printf '  %sSKIPPED: no sibling gcp-apigee-* bundles alongside this one.%s\n' "${YELLOW}" "${NC}"
    exit 0
fi

RC=0
for rel in ${SHARED_FILES}; do
    mine="${HERE}/${rel}"
    if [ ! -f "${mine}" ]; then
        printf '  %s✗%s %s is missing from %s\n' "${RED}" "${NC}" "${rel}" "${SELF_BUNDLE}"
        RC=1
        continue
    fi
    want="$(sum "${mine}")"
    diverged=""
    for name in ${siblings}; do
        theirs="${COLLECTION_DIR}/${name}/.test/${rel}"
        if [ ! -f "${theirs}" ]; then
            diverged="${diverged}\n      ${name}: ABSENT"
            continue
        fi
        got="$(sum "${theirs}")"
        [ "${got}" = "${want}" ] || diverged="${diverged}\n      ${name}: ${got}"
    done
    if [ -n "${diverged}" ]; then
        printf '  %s✗%s %s has diverged\n' "${RED}" "${NC}" "${rel}"
        printf '      %s: %s (this bundle)' "${SELF_BUNDLE}" "${want}"
        # shellcheck disable=SC2059
        printf "${diverged}\n"
        printf '      fix: copy the correct version over the others in the same commit.\n'
        RC=1
    else
        printf '  %s✓%s %s matches all %d sibling(s)\n' "${GREEN}" "${NC}" "${rel}" "${sibling_count}"
    fi
done

exit "${RC}"
