#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Template render tier for gcp-apigee-proxy-health.
#
# Renders the SLX and taskset templates through the same jinja2 configuration
# runwhen-local uses and asserts on the result. Complements .test/offline's
# static section, which greps the templates: grepping catches a known
# regression, rendering catches the class -- notably that reaching through an
# absent attribute RAISES under plain jinja2.Undefined rather than falling back.
#
# Needs jinja2 and pyyaml. When they are missing this SKIPS, and says so loudly
# with a non-silent marker: a tier that quietly reports success when it did not
# run is the exact failure mode this bundle exists to prevent.
#
#   ./run.sh
# -----------------------------------------------------------------------------
set -uo pipefail

# BASH_SOURCE is unset under go-task (mvdan.cc/sh), where dirname "" yields "."
# and silently resolves against the caller's CWD. Fall back to $0, which both
# shells set.
_self="${BASH_SOURCE[0]:-$0}"
HERE="$(cd "$(dirname "${_self}")" && pwd)"
TEMPLATES="$(cd "${HERE}/../.." && pwd)/.runwhen/templates"

BLUE=$'\033[0;34m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'

printf '%s== template render tier%s\n' "${BLUE}" "${NC}"

PY="${PYTHON:-python3}"
if ! command -v "${PY}" >/dev/null 2>&1; then
    printf '%s  SKIPPED: no %s on PATH -- templates were NOT rendered%s\n' \
        "${YELLOW}" "${PY}" "${NC}"
    exit 0
fi
if ! "${PY}" -c 'import jinja2, yaml' >/dev/null 2>&1; then
    printf '%s  SKIPPED: jinja2/pyyaml not installed -- templates were NOT rendered%s\n' \
        "${YELLOW}" "${NC}"
    printf '    install with: %s -m pip install jinja2 pyyaml\n' "${PY}"
    exit 0
fi

exec "${PY}" "${HERE}/check.py" "${TEMPLATES}"
