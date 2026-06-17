#!/usr/bin/env bash
# shellcheck disable=SC2034

# Shared MongoDB Atlas Admin API v2 helpers (digest auth, JSON parsing).

ATLAS_API_BASE="${ATLAS_API_BASE:-https://cloud.mongodb.com/api/atlas/v2}"
ATLAS_ACCEPT_HEADER="${ATLAS_ACCEPT_HEADER:-application/vnd.atlas.2025-02-19+json}"

atlas_resolve_credentials() {
  if [[ -n "${ATLAS_PUBLIC_API_KEY:-}" && -n "${ATLAS_PRIVATE_API_KEY:-}" ]]; then
    return 0
  fi
  local raw="${secret__atlas_api_key_credentials:-}"
  raw="${raw:-${atlas_api_key_credentials:-}}"
  raw="${raw:-${ATLAS_API_KEY_CREDENTIALS_JSON:-}}"
  if [[ -z "$raw" ]]; then
    return 1
  fi
  export ATLAS_PUBLIC_API_KEY="$(echo "$raw" | jq -r '.ATLAS_PUBLIC_API_KEY // .publicKey // empty')"
  export ATLAS_PRIVATE_API_KEY="$(echo "$raw" | jq -r '.ATLAS_PRIVATE_API_KEY // .privateKey // empty')"
  if [[ -z "$ATLAS_PUBLIC_API_KEY" || -z "$ATLAS_PRIVATE_API_KEY" ]]; then
    return 1
  fi
  return 0
}

# GET path like /groups/foo/clusters — writes body to stdout, HTTP status to atlas_last_http_status
atlas_http_get_raw() {
  local path="$1"
  atlas_last_http_status=""
  atlas_last_http_body=""
  local url="${ATLAS_API_BASE}${path}"
  local resp_file status_file
  resp_file="$(mktemp)"
  status_file="$(mktemp)"
  set +e
  curl -sS -w "%{http_code}" --digest --user "${ATLAS_PUBLIC_API_KEY}:${ATLAS_PRIVATE_API_KEY}" \
    -H "Accept: ${ATLAS_ACCEPT_HEADER}" \
    -o "${resp_file}" \
    "${url}" >"${status_file}" 2>/dev/null
  local curl_ec=$?
  set -e
  atlas_last_http_status="$(cat "${status_file}" 2>/dev/null || printf '%s' '')"
  rm -f "${status_file}"
  if [[ "${curl_ec}" != 0 ]]; then
    atlas_last_http_body="$(cat "${resp_file}" 2>/dev/null || true)"
    rm -f "${resp_file}"
    return 2
  fi
  atlas_last_http_body="$(cat "${resp_file}" 2>/dev/null || true)"
  rm -f "${resp_file}"
  return 0
}

atlas_clusters_json() {
  local group_id="$1"
  atlas_http_get_raw "/groups/$(printf '%s' "${group_id}" | jq -sRr @uri)/clusters?itemsPerPage=500"
}

atlas_processes_json() {
  local group_id="$1"
  atlas_http_get_raw "/groups/$(printf '%s' "${group_id}" | jq -sRr @uri)/processes?itemsPerPage=500"
}

# URL-encoded process id for measurements path segment
atlas_encoded_process_path() {
  local pid="$1"
  printf '%s' "${pid}" | jq -sRr @uri
}

atlas_measurement_json() {
  local group_id="$1"
  local process_id="$2"
  local query="$3"
  local enc
  enc="$(atlas_encoded_process_path "${process_id}")"
  atlas_http_get_raw "/groups/$(printf '%s' "${group_id}" | jq -sRr @uri)/processes/${enc}/measurements${query}"
}

latest_nonnull_metric_max() {
  local json_payload="$1"
  local metric_name="$2"
  echo "$json_payload" | jq -r --arg n "$metric_name" '
    [.measurements[]? | select(.name == $n) | .dataPoints[]? | select(.value != null) | .value] | max // empty
  '
}

append_issue_json() {
  local cur="$1"
  local title="$2"
  local details="$3"
  local severity="$4"
  local next_steps="$5"
  echo "$cur" | jq \
    --arg title "$title" \
    --arg details "$details" \
    --argjson severity "${severity}" \
    --arg next_steps "$next_steps" \
    '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]'
}

cluster_matches_filter() {
  local cluster_name="$1"
  local filter_csv="$2"
  if [[ -z "$filter_csv" ]]; then
    return 0
  fi
  IFS=',' read -ra parts <<<"${filter_csv}"
  for tok in "${parts[@]}"; do
    stripped="${tok#"${tok%%[![:space:]]*}"}"
    stripped="${stripped%"${stripped##*[![:space:]]}"}"
    [[ -z "$stripped" ]] && continue
    if [[ "$cluster_name" == "$stripped" ]]; then
      return 0
    fi
  done
  return 1
}

filter_clusters_by_name() {
  local clusters_json="$1"
  local filter_csv="$2"
  if [[ -z "$filter_csv" ]]; then
    echo "$clusters_json" | jq -c '[.results[]?]'
    return 0
  fi
  echo "$clusters_json" | jq -c --arg f "$filter_csv" '
    $f as $csv
    | ($csv | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0))) as $names
    | [.results[]? | select(.name as $n | $names | index($n) != null)]
  '
}
