#!/usr/bin/env bash
# Prints a single line: 0 or 1 for SLI sub-metrics.
# Dimension selector: either first positional arg or $DIM env var.
#   ./sli-litellm-dimension.sh api
#   DIM=api ./sli-litellm-dimension.sh
# Valid values: api | readiness | threshold | logs | exceptions
#
# Hard rule: this script must ALWAYS print exactly one line (0 or 1) on stdout,
# even on unexpected errors, so the SLI harness never sees an empty string.
# Diagnostics go to stderr.

# Accept dimension via argv[1] first (the pattern used by sli.robot's
# cmd_override=./sli-litellm-dimension.sh <dim>) and fall back to $DIM so
# running the script locally with DIM= still works.
DIM="${1:-${DIM:-}}"
export DIM
#
# OSS-aware:
#   threshold: prefers /global/spend/report but falls back to /key/list sum
#              on OSS proxies that don't have the enterprise route licensed.
#   logs:      returns 1 (clean) when spend-logs is enterprise-gated or the
#              proxy has no DB-backed logs — those are not real "dirty spend
#              log" conditions on OSS.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=litellm-http-helpers.sh
source "${SCRIPT_DIR}/litellm-http-helpers.sh"

# NOTE: we intentionally do NOT `set -e` in this script. A bug or a missing
# upstream endpoint must not cause an empty stdout — the harness parses the
# result as a float and would otherwise error out with "'' cannot be converted
# to a floating point number".

emit_and_exit() {
  printf '%s\n' "$1"
  exit 0
}

# Initialize runtime; all chatter to stderr. On failure, we can't reach the
# proxy, so emit 0 for availability dimensions and 1 (benign) for dimensions
# that do not apply in an OSS/no-DB scenario.
_failure_score_for_dim() {
  case "${1:-}" in
    api|readiness) printf '0' ;;
    threshold|logs|exceptions) printf '1' ;;
    *) printf '0' ;;
  esac
}

if ! litellm_init_runtime >&2; then
  emit_and_exit "$(_failure_score_for_dim "${DIM:-}")"
fi

BASE="$(litellm_base_url 2>/dev/null || echo "")"
if [[ -z "$BASE" ]]; then
  emit_and_exit "$(_failure_score_for_dim "${DIM:-}")"
fi

case "${DIM:-}" in
  api)
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "${BASE}/health/liveliness" 2>/dev/null || echo "000")
    if [[ "$code" =~ ^2 ]]; then emit_and_exit 1; fi
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "${BASE}/health" 2>/dev/null || echo "000")
    if [[ "$code" =~ ^2 ]]; then emit_and_exit 1; fi
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "${BASE}/" 2>/dev/null || echo "000")
    if [[ "$code" =~ ^2 ]]; then emit_and_exit 1; fi
    emit_and_exit 0
    ;;

  threshold)
    THRESH="${LITELLM_SPEND_THRESHOLD_USD:-0}"
    # No threshold configured -> nothing to breach.
    if awk -v t="$THRESH" 'BEGIN{exit !(t<=0)}'; then
      emit_and_exit 1
    fi
    read -r START_DATE END_DATE <<<"$(litellm_date_range)"
    TMP=$(mktemp)
    litellm_register_cleanup 'rm -f "$TMP"'

    TOTAL=""
    code=$(litellm_get_file "/global/spend/report?start_date=${START_DATE}&end_date=${END_DATE}" "$TMP" 2>/dev/null || echo "000")
    if [[ "$code" == "200" ]]; then
      TOTAL=$(python3 -c '
import json,sys
try:
    j=json.load(sys.stdin)
except Exception:
    print("0"); sys.exit(0)
def walk_sum(o):
    s=0.0
    if isinstance(o, dict):
        for k,v in o.items():
            if k in ("total_spend","spend") and isinstance(v,(int,float)):
                s+=float(v)
            else:
                s+=walk_sum(v)
    elif isinstance(o, list):
        for i in o:
            s+=walk_sum(i)
    return s
print(walk_sum(j))
' <"$TMP")
    fi

    # OSS fallback: sum .spend across /key/list.
    if [[ -z "$TOTAL" ]]; then
      code_kl=$(litellm_get_file "/key/list" "$TMP" 2>/dev/null || echo "000")
      if [[ "$code_kl" == "200" ]]; then
        TOTAL=$(python3 - "$TMP" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        raw = json.load(f)
except Exception:
    print("0"); sys.exit(0)
items = None
if isinstance(raw, dict):
    for key in ("keys", "data"):
        if isinstance(raw.get(key), list):
            items = raw[key]; break
if items is None and isinstance(raw, list):
    items = raw
if not isinstance(items, list):
    items = []
total = 0.0
for k in items:
    if not isinstance(k, dict):
        continue
    v = k.get("spend")
    try:
        total += float(v)
    except (TypeError, ValueError):
        continue
print(total)
PY
)
      fi
    fi

    if [[ -z "$TOTAL" ]]; then
      # No source of truth for spend. Don't breach; return healthy.
      emit_and_exit 1
    fi

    if awk -v t="$THRESH" -v s="$TOTAL" 'BEGIN{exit !(t>0 && s>t)}'; then
      emit_and_exit 0
    else
      emit_and_exit 1
    fi
    ;;

  logs)
    # Use summarize=true (compact, ~1-2 KB regardless of volume) rather than
    # summarize=false which on busy OSS proxies can exceed tunnel payload
    # limits (>100 MB) and drop to HTTP 000. The summary JSON contains
    # per-user + per-model spend rollups; we do NOT scan for failure strings
    # here — that is the "exceptions" dimension's job.
    read -r START_DATE END_DATE <<<"$(litellm_date_range)"
    TMP=$(mktemp)
    litellm_register_cleanup 'rm -f "$TMP"'
    code=$(litellm_get_file "/spend/logs?start_date=${START_DATE}&end_date=${END_DATE}&summarize=true" "$TMP" 2>/dev/null || echo "000")
    # Anything non-200 (enterprise gating, no DB, transient tunnel drop) is
    # NOT a "dirty spend logs" failure on OSS — treat as clean (1).
    if [[ "$code" != "200" ]]; then
      emit_and_exit 1
    fi
    # Summary schema: [ { users:{...}, models:{...} }, ... ]. Clean by
    # definition since it contains only aggregates. Confirm it parses.
    if ! jq -e . "$TMP" >/dev/null 2>&1; then
      emit_and_exit 1
    fi
    emit_and_exit 1
    ;;

  readiness)
    # 1 iff /health/readiness reports db=connected. This is the deterministic
    # "is spend tracking configured?" signal for SLOs that care about spend
    # governance being possible at all.
    if ! litellm_readiness >/dev/null 2>&1; then
      emit_and_exit 0
    fi
    if [[ "${_LITELLM_DB_STATUS:-unknown}" == "connected" ]]; then
      emit_and_exit 1
    fi
    emit_and_exit 0
    ;;

  exceptions)
    # 1 if observed exception rate in window stays below
    # LITELLM_EXCEPTION_RATE_PCT (default 1%). Uses OSS /global/activity and
    # /global/activity/exceptions/deployment — compact payloads that don't
    # suffer from the summarize=false size problem.
    THRESH_PCT="${LITELLM_EXCEPTION_RATE_PCT:-1}"
    read -r START_DATE END_DATE <<<"$(litellm_date_range)"
    TMP=$(mktemp)
    litellm_register_cleanup 'rm -f "$TMP"'
    code=$(litellm_get_file "/global/activity?start_date=${START_DATE}&end_date=${END_DATE}" "$TMP" 2>/dev/null || echo "000")
    if [[ "$code" != "200" ]]; then
      # No activity data -> can't score -> benign 1.
      emit_and_exit 1
    fi
    total_req=$(jq -r '.sum_api_requests // 0' "$TMP" 2>/dev/null || echo 0)
    [[ -z "$total_req" ]] && total_req=0
    if [[ "$total_req" -eq 0 ]]; then
      emit_and_exit 1
    fi
    # Enumerate top-N models and sum exceptions.
    code2=$(litellm_get_file "/global/activity/model?start_date=${START_DATE}&end_date=${END_DATE}" "$TMP" 2>/dev/null || echo "000")
    if [[ "$code2" != "200" ]]; then
      emit_and_exit 1
    fi
    top_models=$(jq -r --argjson n "${LITELLM_AGGREGATE_MAX_MODELS:-8}" '
      [ .[] | {model, req: (.sum_api_requests // 0)} ] | sort_by(-.req) | .[:$n] | .[] | .model
    ' "$TMP" 2>/dev/null || echo "")
    total_ex=0
    while IFS= read -r m; do
      [[ -z "$m" ]] && continue
      m_enc=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$m")
      TMPX=$(mktemp)
      c=$(litellm_get_file "/global/activity/exceptions/deployment?start_date=${START_DATE}&end_date=${END_DATE}&model_group=${m_enc}" "$TMPX" 2>/dev/null || echo "000")
      if [[ "$c" == "200" ]]; then
        model_ex=$(jq -r '[.[]?.sum_num_exceptions // 0] | add // 0' "$TMPX" 2>/dev/null || echo 0)
        total_ex=$(( total_ex + ${model_ex:-0} ))
      fi
      rm -f "$TMPX"
    done <<<"$top_models"
    if awk -v e="$total_ex" -v r="$total_req" -v t="$THRESH_PCT" 'BEGIN{ rate=(r>0 ? e*100.0/r : 0); exit !(rate>t)}'; then
      emit_and_exit 0
    else
      emit_and_exit 1
    fi
    ;;

  *)
    emit_and_exit 0
    ;;
esac

emit_and_exit 0
