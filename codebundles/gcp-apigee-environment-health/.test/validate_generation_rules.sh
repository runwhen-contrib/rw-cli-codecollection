#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# validate_generation_rules.sh -- check .runwhen/generation-rules against the
# published JSON Schema.
#
# SHARED SUBSTRATE. Byte-identical in every gcp-apigee-* bundle;
# check-shared-drift.sh fails `task ci` when it is not.
#
# WHY THIS IS NOT JUST `ajv`.
#
# 44 of the 47 bundles that validate their rules shell out to ajv-cli, and that
# is the collection's convention -- but ajv is a Node tool, and the standard
# codecollection-devtools image ships neither node nor npm nor ajv. So `task ci`
# -- the credential-free gate this whole family is supposed to run through --
# could not complete in the one container everyone tests in.
#
# The obvious workarounds are both wrong:
#
#   * Skip when ajv is missing. That is what the three non-ajv bundles in this
#     collection do ("Warning: ... Skipping validation" then exit 0), and it is
#     the exact failure this family keeps designing against: an absent check
#     reports the same green as a passing one.
#   * Downgrade to `yaml.safe_load()`. That proves the file is YAML, not that it
#     satisfies the schema, so a rule that parses but gates on a resource type
#     that does not exist sails through.
#
# So: use ajv when it is there (unchanged behaviour, and what CI has), fall back
# to Python's jsonschema when it is not, and FAIL when neither is available --
# naming both install routes, because which one applies depends on the image.
#
# The two agree: both accept all five bundles' current rules and both reject a
# rule with a non-string apiVersion and a scalar where resourceTypes must be an
# array. jsonschema reports every error with its path, which ajv does not.
#
# Usage: ./validate_generation_rules.sh
# Exit 0 when every rule validates, 1 on any failure -- including "no validator"
# and "no rules found".
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_DIR="${HERE}/../.runwhen/generation-rules"
SCHEMA_URL="${GENERATION_RULE_SCHEMA_URL:-https://raw.githubusercontent.com/runwhen-contrib/runwhen-local/refs/heads/main/src/generation-rule-schema.json}"

for cmd in curl yq jq; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "ERROR: ${cmd} is required but not installed." >&2
        exit 1
    fi
done

# --- pick a validator --------------------------------------------------------
VALIDATOR=""
if command -v ajv >/dev/null 2>&1; then
    VALIDATOR="ajv"
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; then
    VALIDATOR="jsonschema"
else
    echo "ERROR: no JSON Schema validator available." >&2
    echo "       The generation rules gate discovery, so this is not something to" >&2
    echo "       skip -- a rule that does not validate produces zero SLXs and reads" >&2
    echo "       as 'nothing matched'." >&2
    echo "" >&2
    echo "       Install ONE of:" >&2
    echo "         npm install -g ajv-cli        # the collection's convention" >&2
    echo "         pip install jsonschema        # no node required" >&2
    exit 1
fi
echo "Validating with: ${VALIDATOR}"

temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT
schema="${temp_dir}/generation-rule-schema.json"

# -f matters: an unchecked `curl -s` writes GitHub's error page (or nothing) to
# the schema on a 404 or network blip. Every rule then "fails" against that
# garbage while the task still exits 0, so an outage is indistinguishable from
# broken rules and from success.
if ! curl -fsS -o "${schema}" "${SCHEMA_URL}"; then
    echo "ERROR: could not download the generation-rule schema from ${SCHEMA_URL}" >&2
    exit 1
fi
if ! jq -e . "${schema}" >/dev/null 2>&1; then
    echo "ERROR: downloaded generation-rule schema is not valid JSON" >&2
    exit 1
fi

# The jsonschema path needs a script; write it once rather than passing a
# multi-line -c through the shell.
if [ "${VALIDATOR}" = "jsonschema" ]; then
    cat > "${temp_dir}/validate.py" <<'PYEOF'
import json, sys
from jsonschema import Draft202012Validator

schema = json.load(open(sys.argv[1]))
doc = json.load(open(sys.argv[2]))
errors = sorted(Draft202012Validator(schema).iter_errors(doc), key=lambda e: list(e.path))
for e in errors:
    location = "/".join(str(p) for p in e.path) or "(root)"
    print("    %s: %s" % (location, e.message), file=sys.stderr)
sys.exit(1 if errors else 0)
PYEOF
fi

validate_one() {
    # validate_one <json_file> -> 0 valid, 1 invalid
    case "${VALIDATOR}" in
        ajv)
            # --strict=false because the published schema uses keywords ajv
            # considers non-standard; --spec=draft2020 to match its $schema.
            ajv validate -s "${schema}" -d "$1" --spec=draft2020 --strict=false
            ;;
        jsonschema)
            python3 "${temp_dir}/validate.py" "${schema}" "$1"
            ;;
    esac
}

rules_found=0
failed=0
for yaml_file in "${RULES_DIR}"/*.yaml; do
    # An unmatched glob expands to itself; without this a missing or renamed
    # directory would validate nothing and report success.
    [ -e "${yaml_file}" ] || continue
    rules_found=$((rules_found + 1))
    echo "Validating ${yaml_file}"
    json_file="${temp_dir}/$(basename "${yaml_file%.*}").json"
    if ! yq -o=json "${yaml_file}" > "${json_file}"; then
        echo "  ERROR: ${yaml_file} could not be converted to JSON" >&2
        failed=$((failed + 1))
        continue
    fi
    # NOT `validate && echo valid || echo invalid`: that form made the block's
    # exit status the trailing command, so an invalid rule printed "is invalid"
    # and the task still exited 0.
    if validate_one "${json_file}"; then
        echo "  ${yaml_file} is valid."
    else
        echo "  ERROR: ${yaml_file} is invalid." >&2
        failed=$((failed + 1))
    fi
done

if [ "${rules_found}" -eq 0 ]; then
    echo "ERROR: no generation rules found under ${RULES_DIR}" >&2
    exit 1
fi
if [ "${failed}" -gt 0 ]; then
    echo "${failed} of ${rules_found} generation rule(s) failed validation." >&2
    exit 1
fi
echo "All ${rules_found} generation rule(s) valid."
