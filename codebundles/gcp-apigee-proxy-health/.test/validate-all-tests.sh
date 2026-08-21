#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# validate-all-tests.sh -- run every tier that needs no cloud, no credentials
# and no spend, and fail if any of them fails.
#
# SHARED SUBSTRATE. Byte-identical in every gcp-apigee-* bundle;
# check-shared-drift.sh fails `task ci` when it is not.
#
#   offline/run.sh          exercises the bundle's check scripts against canned
#                           API responses and asserts on what they report. Also
#                           checks the generation rule, templates and runbook
#                           wiring statically.
#   render/run.sh           renders the SLX and taskset templates through the
#                           same jinja2 configuration runwhen-local uses and
#                           asserts on the result. Needs jinja2 + pyyaml; SKIPS
#                           loudly without them rather than reporting a pass.
#   check-shared-drift.sh   fails when a file meant to be byte-identical across
#                           the gcp-apigee-* bundles has diverged.
#
# The two test tiers are complementary and neither replaces the other: the
# offline tier greps the templates, which catches a regression whose shape is
# already known, while the render tier catches the class it belongs to --
# notably that reaching through an absent attribute RAISES under plain
# jinja2.Undefined rather than falling back.
#
# This is the same set `task ci` runs, minus validate-generation-rules, which
# needs network access to fetch the published schema. Use this when `task` is
# not available; use `task ci` in CI.
#
# Usage: ./validate-all-tests.sh
# Exit code 0 on success, 1 on any assertion failure.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC=0

# Each tier runs even when an earlier one failed. Stopping at the first failure
# hides how much is broken, and these are cheap.
"${HERE}/offline/run.sh"          || RC=1
"${HERE}/render/run.sh"           || RC=1
"${HERE}/check-shared-drift.sh"   || RC=1

echo
if [ "${RC}" -ne 0 ]; then
    echo "FAILED: at least one credential-free tier reported a failure."
else
    echo "All credential-free tiers passed."
fi
exit "${RC}"
