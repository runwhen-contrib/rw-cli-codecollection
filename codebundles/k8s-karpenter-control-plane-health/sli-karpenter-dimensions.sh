#!/usr/bin/env bash
set -euo pipefail
# -----------------------------------------------------------------------------
# Lightweight SLI dimensions (stdout JSON): scores for controller, webhooks,
# warning events, and service endpoints. Used by sli.robot only.
# -----------------------------------------------------------------------------
: "${CONTEXT:?Must set CONTEXT}"
: "${KARPENTER_NAMESPACE:?Must set KARPENTER_NAMESPACE}"

KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
RW_LOOKBACK_WINDOW="${RW_LOOKBACK_WINDOW:-30m}"
WARN_TH="${SLI_WARNING_EVENT_THRESHOLD:-5}"

parse_minutes() {
  local t="${1:-30m}"
  if [[ "$t" =~ ^([0-9]+)m$ ]]; then echo "${BASH_REMATCH[1]}"
  elif [[ "$t" =~ ^([0-9]+)h$ ]]; then echo $((${BASH_REMATCH[1]} * 60))
  elif [[ "$t" =~ ^[0-9]+$ ]]; then echo "$t"
  else echo "30"
  fi
}

MINUTES=$(parse_minutes "$RW_LOOKBACK_WINDOW")
THRESHOLD_TIME=$(date -u -d "@$(($(date +%s) - MINUTES * 60))" +"%Y-%m-%dT%H:%M:%SZ")

controller_score=1
webhook_score=1
warning_score=1
service_score=1

if ! "${KUBECTL}" get ns "${KARPENTER_NAMESPACE}" --context "${CONTEXT}" -o name &>/dev/null; then
  jq -n '{controller: 0, webhook: 0, warnings: 0, service: 0}'
  exit 0
fi

pods_json=$("${KUBECTL}" get pods -n "${KARPENTER_NAMESPACE}" --context "${CONTEXT}" -l 'app.kubernetes.io/name=karpenter' -o json 2>/dev/null || echo '{"items":[]}')
if [[ $(echo "$pods_json" | jq '.items | length') -eq 0 ]]; then
  pods_json=$("${KUBECTL}" get pods -n "${KARPENTER_NAMESPACE}" --context "${CONTEXT}" -o json)
  pods_json=$(echo "$pods_json" | jq '{items: [.items[] | select(
      (.metadata.labels["app.kubernetes.io/name"]? == "karpenter") or
      (.metadata.name | test("karpenter"))
    )]}')
fi

if [[ $(echo "$pods_json" | jq '.items | length') -eq 0 ]]; then
  controller_score=0
else
  not_ready=$(echo "$pods_json" | jq '[.items[] | select(
      ((.status.conditions // []) | map(select(.type=="Ready")) | .[0].status // "False") != "True"
    )] | length')
  [[ "${not_ready:-0}" -gt 0 ]] && controller_score=0
fi

ev=$("${KUBECTL}" get events -n "${KARPENTER_NAMESPACE}" --context "${CONTEXT}" --field-selector type=Warning -o json 2>/dev/null || echo '{"items":[]}')
wcount=$(echo "$ev" | jq --arg th "$THRESHOLD_TIME" '[.items[] | select((.lastTimestamp // .eventTime // "1970-01-01T00:00:00Z") > $th)] | length')
if [[ "${wcount:-999}" -gt "${WARN_TH}" ]]; then warning_score=0; fi

svc_json=$("${KUBECTL}" get svc -n "${KARPENTER_NAMESPACE}" --context "${CONTEXT}" -o json 2>/dev/null || echo '{"items":[]}')
svc_name=$(echo "$svc_json" | jq -r '[.items[] | select(.metadata.name | test("karpenter"; "i")) | .metadata.name] | .[0] // empty')
if [[ -z "$svc_name" ]]; then
  service_score=0
else
  ep=$("${KUBECTL}" get endpoints "$svc_name" -n "${KARPENTER_NAMESPACE}" --context "${CONTEXT}" -o json 2>/dev/null || echo '{}')
  acn=$(echo "$ep" | jq '[.subsets[]? | .addresses[]?] | length')
  [[ "${acn:-0}" -eq 0 ]] && service_score=0
fi

vwh=$("${KUBECTL}" get validatingwebhookconfiguration -o json --context "${CONTEXT}" 2>/dev/null || echo '{"items":[]}')
wh_found=$(echo "$vwh" | jq --arg ns "$KARPENTER_NAMESPACE" '[.items[] | select(
  (.metadata.name | test("karpenter"; "i")) or
  (any(.webhooks[]?; (.clientConfig.service.namespace? // "") == $ns))
)] | length')
[[ "${wh_found:-0}" -eq 0 ]] && webhook_score=0

jq -n \
  --argjson c "$controller_score" \
  --argjson w "$webhook_score" \
  --argjson e "$warning_score" \
  --argjson s "$service_score" \
  '{controller: $c, webhook: $w, warnings: $e, service: $s}'
