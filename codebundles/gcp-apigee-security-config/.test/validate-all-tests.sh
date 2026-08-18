#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# validate-all-tests.sh -- runs every tier that needs no cloud, no credentials
# and no spend, and fails if any of them fails.
#
#   offline/run.sh   runs the bundle scripts against canned Apigee API responses
#                    and Cloud Monitoring aggregates, and asserts on what they
#                    report; also checks the generation rule, templates and
#                    runbook wiring statically.
#   render/run.sh    renders the SLX and taskset templates through the same
#                    jinja2 configuration runwhen-local uses and asserts on the
#                    result. Needs jinja2 + pyyaml; SKIPS loudly without them.
#
# The two are complementary and neither replaces the other: the offline tier
# greps the templates, which catches a regression whose shape is already known,
# while the render tier catches the class it belongs to -- notably that reaching
# through an absent attribute RAISES under plain jinja2.Undefined rather than
# falling back.
#
# Usage: ./validate-all-tests.sh
# Exit code 0 on success, 1 on any assertion failure.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC=0

"${HERE}/offline/run.sh" || RC=1
"${HERE}/render/run.sh"  || RC=1

echo
if [ "${RC}" -ne 0 ]; then
    echo "FAILED: at least one tier reported a failure."
else
    echo "All offline tiers passed."
fi
exit "${RC}"
