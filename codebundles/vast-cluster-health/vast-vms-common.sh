#!/usr/bin/env bash
# Shared helpers for VAST VMS REST and Prometheus exporter access.
# shellcheck disable=SC2034

set -euo pipefail

: "${VAST_VMS_ENDPOINT:?Must set VAST_VMS_ENDPOINT}"
: "${VAST_CLUSTER_NAME:?Must set VAST_CLUSTER_NAME}"

VAST_VMS_ENDPOINT="${VAST_VMS_ENDPOINT%/}"
CAPACITY_THRESHOLD="${CAPACITY_THRESHOLD:-85}"
CRITICAL_CAPACITY_THRESHOLD="${CRITICAL_CAPACITY_THRESHOLD:-95}"
VAST_TLS_INSECURE="${VAST_TLS_INSECURE:-true}"
VAST_CURL_TIMEOUT="${VAST_CURL_TIMEOUT:-60}"

_vast_load_credentials() {
  local creds_json="${1:-}"
  if [[ -z "$creds_json" && -n "${VAST_VMS_CREDENTIALS_FILE:-}" && -f "${VAST_VMS_CREDENTIALS_FILE}" ]]; then
    creds_json="$(cat "${VAST_VMS_CREDENTIALS_FILE}")"
  fi
  if [[ -z "$creds_json" && -n "${VAST_VMS_CREDENTIALS_JSON:-}" ]]; then
    creds_json="${VAST_VMS_CREDENTIALS_JSON}"
  fi
  if [[ -z "$creds_json" ]]; then
    echo "VAST credentials not configured (set vast_vms_credentials secret with USERNAME/PASSWORD or API_TOKEN)" >&2
    return 1
  fi
  VAST_API_USERNAME="$(echo "$creds_json" | jq -r '.USERNAME // .username // empty')"
  VAST_API_PASSWORD="$(echo "$creds_json" | jq -r '.PASSWORD // .password // empty')"
  VAST_API_TOKEN="$(echo "$creds_json" | jq -r '.API_TOKEN // .api_token // .token // empty')"
  export VAST_API_USERNAME VAST_API_PASSWORD VAST_API_TOKEN
}

_vast_fixture_path() {
  local kind="$1"
  if [[ -n "${VAST_MOCK_FIXTURE_DIR:-}" ]]; then
    local candidate="${VAST_MOCK_FIXTURE_DIR}/${kind}"
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  fi
  return 1
}

_vast_curl_common_args() {
  local args=(-sS --connect-timeout 10 --max-time "${VAST_CURL_TIMEOUT}")
  if [[ "${VAST_TLS_INSECURE}" == "true" ]]; then
    args+=(-k)
  fi
  if [[ -n "${VAST_API_TOKEN:-}" ]]; then
    args+=(-H "Authorization: Bearer ${VAST_API_TOKEN}")
  elif [[ -n "${VAST_API_USERNAME:-}" && -n "${VAST_API_PASSWORD:-}" ]]; then
    args+=(-u "${VAST_API_USERNAME}:${VAST_API_PASSWORD}")
  fi
  printf '%s\n' "${args[@]}"
}

vast_api_get() {
  local path="$1"
  local fixture
  if fixture="$(_vast_fixture_path "api${path//\//_}")"; then
    cat "$fixture"
    return 0
  fi
  mapfile -t curl_args < <(_vast_curl_common_args)
  curl "${curl_args[@]}" -H "Accept: application/json" "${VAST_VMS_ENDPOINT}${path}"
}

vast_prometheus_get() {
  local endpoint="$1"
  local fixture
  if fixture="$(_vast_fixture_path "prometheus_${endpoint//\//_}")"; then
    cat "$fixture"
    return 0
  fi
  mapfile -t curl_args < <(_vast_curl_common_args)
  curl "${curl_args[@]}" "${VAST_VMS_ENDPOINT}/api/prometheusmetrics/${endpoint}"
}

vast_prometheus_gauge() {
  local metrics_text="$1"
  local metric_name="$2"
  echo "$metrics_text" | awk -v name="$metric_name" '
    $0 !~ /^#/ && $1 ~ name {
      val = $2
      gsub(/[^0-9.eE+-]/, "", val)
      if (val != "") { print val; exit }
    }
    END { if (NR == 0) exit 1 }
  ' 2>/dev/null || echo ""
}

vast_prometheus_metric_sum() {
  local metrics_text="$1"
  local metric_regex="$2"
  echo "$metrics_text" | awk -v re="$metric_regex" '
    $0 !~ /^#/ && $1 ~ re {
      val = $2
      gsub(/[^0-9.eE+-]/, "", val)
      if (val != "") sum += val
    }
    END { printf "%.0f", sum+0 }
  '
}

vast_find_cluster_json() {
  local clusters_json="$1"
  local cluster_name="$2"
  echo "$clusters_json" | jq -c --arg name "$cluster_name" '
    (if type == "array" then . elif .results then .results elif .clusters then .clusters else [.] end)
    | map(select((.name // .title // "") | ascii_downcase == ($name | ascii_downcase)))
    | .[0] // empty
  '
}

vast_append_issue() {
  local issues_json="$1"
  local title="$2"
  local details="$3"
  local severity="$4"
  local next_steps="$5"
  echo "$issues_json" | jq \
    --arg title "$title" \
    --arg details "$details" \
    --arg severity "$severity" \
    --arg next_steps "$next_steps" \
    '. += [{
      "title": $title,
      "details": $details,
      "severity": ($severity | tonumber),
      "next_steps": $next_steps
    }]'
}

vast_api_error_issue() {
  local issues_json="$1"
  local context="$2"
  local err_msg="$3"
  vast_append_issue "$issues_json" \
    "Cannot Access VAST Cluster \`${VAST_CLUSTER_NAME}\` (${context})" \
    "VMS API call failed: ${err_msg}" \
    "4" \
    "Verify VAST_VMS_ENDPOINT, network connectivity, and vast_vms_credentials permissions"
}

vast_init_issues() {
  echo '[]'
}
