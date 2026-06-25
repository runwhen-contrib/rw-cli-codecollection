#!/usr/bin/env bash
# Shared helpers for SeaweedFS healthcheck scripts.
# shellcheck disable=SC2034
set -euo pipefail

KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
MASTER_PORT="${SEAWEEDFS_MASTER_PORT:-9333}"
VOLUME_PORT="${SEAWEEDFS_VOLUME_PORT:-8080}"
FILER_PORT="${SEAWEEDFS_FILER_PORT:-8888}"
S3_PORT="${SEAWEEDFS_S3_PORT:-8333}"

issues_json='[]'
COMPONENT_MAP_FILE="${COMPONENT_MAP_FILE:-seaweedfs_component_map.json}"

swf_add_issue() {
  local title="$1"
  local details="$2"
  local severity="$3"
  local next_steps="$4"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "$title" \
    --arg details "$details" \
    --argjson severity "$severity" \
    --arg next_steps "$next_steps" \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
}

swf_write_issues() {
  local output_file="$1"
  echo "$issues_json" >"$output_file"
}

swf_release_selector() {
  if [[ -n "${SEAWEEDFS_RELEASE_NAME:-}" ]]; then
    echo "app.kubernetes.io/instance=${SEAWEEDFS_RELEASE_NAME}"
    return 0
  fi
  echo ""
}

swf_resolve_release_name() {
  if [[ -n "${SEAWEEDFS_RELEASE_NAME:-}" ]]; then
    echo "${SEAWEEDFS_RELEASE_NAME}"
    return 0
  fi
  local from_label
  from_label=$("${KUBECTL}" get statefulset,deployment -n "${NAMESPACE}" --context "${CONTEXT}" \
    -l 'app.kubernetes.io/name=seaweedfs' -o json 2>/dev/null \
    | jq -r '.items[0].metadata.labels["app.kubernetes.io/instance"] // empty' || true)
  if [[ -n "$from_label" ]]; then
    echo "$from_label"
    return 0
  fi
  local name
  name=$("${KUBECTL}" get statefulset -n "${NAMESPACE}" --context "${CONTEXT}" -o json 2>/dev/null \
    | jq -r '.items[] | select(.metadata.name | test("seaweed"; "i")) | select(.metadata.name | test("master"; "i")) | .metadata.name' \
    | head -n1 || true)
  if [[ -n "$name" ]]; then
    echo "$name" | sed -E 's/-seaweedfs-master$//; s/-master$//'
    return 0
  fi
  echo ""
}

swf_label_selector() {
  local component="${1:-}"
  local release
  release=$(swf_resolve_release_name)
  local parts=()
  parts+=("app.kubernetes.io/name=seaweedfs")
  if [[ -n "$release" ]]; then
    parts+=("app.kubernetes.io/instance=${release}")
  fi
  if [[ -n "$component" ]]; then
    parts+=("app.kubernetes.io/component=${component}")
  fi
  local IFS=','
  echo "${parts[*]}"
}

swf_find_pod() {
  local component="$1"
  local selector
  selector=$(swf_label_selector "$component")
  local pod=""
  if [[ -n "$selector" ]]; then
    pod=$("${KUBECTL}" get pods -n "${NAMESPACE}" --context "${CONTEXT}" \
      -l "$selector" --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  fi
  if [[ -z "$pod" ]]; then
    pod=$("${KUBECTL}" get pods -n "${NAMESPACE}" --context "${CONTEXT}" -o json 2>/dev/null \
      | jq -r --arg c "$component" '.items[] | select(.status.phase=="Running") | select(
          (.metadata.labels["app.kubernetes.io/component"]? == $c) or
          (.metadata.name | test($c; "i"))
        ) | .metadata.name' | head -n1 || true)
  fi
  echo "$pod"
}

swf_pod_http() {
  local pod="$1"
  local port="$2"
  local path="$3"
  [[ -z "$pod" ]] && return 1
  "${KUBECTL}" exec -n "${NAMESPACE}" --context "${CONTEXT}" "$pod" -- \
    sh -c "wget -qO- 'http://127.0.0.1:${port}${path}' 2>/dev/null || curl -sf 'http://127.0.0.1:${port}${path}' 2>/dev/null" 2>/dev/null
}

swf_master_http() {
  local path="$1"
  if [[ -n "${SEAWEEDFS_MASTER_SERVICE:-}" ]]; then
    local host="${SEAWEEDFS_MASTER_SERVICE%%:*}"
    local port="${SEAWEEDFS_MASTER_SERVICE#*:}"
    [[ "$port" == "$host" ]] && port="$MASTER_PORT"
    local svc_pod
    svc_pod=$(swf_find_pod "master")
    [[ -z "$svc_pod" ]] && return 1
    "${KUBECTL}" exec -n "${NAMESPACE}" --context "${CONTEXT}" "$svc_pod" -- \
      sh -c "wget -qO- 'http://${host}:${port}${path}' 2>/dev/null || curl -sf 'http://${host}:${port}${path}' 2>/dev/null" 2>/dev/null
    return $?
  fi
  local pod
  pod=$(swf_find_pod "master")
  swf_pod_http "$pod" "$MASTER_PORT" "$path"
}

swf_filer_http() {
  local path="$1"
  if [[ -n "${SEAWEEDFS_FILER_SERVICE:-}" ]]; then
    local host="${SEAWEEDFS_FILER_SERVICE%%:*}"
    local port="${SEAWEEDFS_FILER_SERVICE#*:}"
    [[ "$port" == "$host" ]] && port="$FILER_PORT"
    local pod
    pod=$(swf_find_pod "filer")
    [[ -z "$pod" ]] && return 1
    "${KUBECTL}" exec -n "${NAMESPACE}" --context "${CONTEXT}" "$pod" -- \
      sh -c "wget -qO- 'http://${host}:${port}${path}' 2>/dev/null || curl -sf 'http://${host}:${port}${path}' 2>/dev/null" 2>/dev/null
    return $?
  fi
  local pod
  pod=$(swf_find_pod "filer")
  swf_pod_http "$pod" "$FILER_PORT" "$path"
}

swf_volume_http() {
  local pod="$1"
  local path="$2"
  swf_pod_http "$pod" "$VOLUME_PORT" "$path"
}

swf_discover_components() {
  local release
  release=$(swf_resolve_release_name)
  local base_selector="app.kubernetes.io/name=seaweedfs"
  if [[ -n "$release" ]]; then
    base_selector="${base_selector},app.kubernetes.io/instance=${release}"
  fi

  local sts_json dep_json svc_json pvc_json
  sts_json=$("${KUBECTL}" get statefulset -n "${NAMESPACE}" --context "${CONTEXT}" -l "$base_selector" -o json 2>/dev/null \
    || "${KUBECTL}" get statefulset -n "${NAMESPACE}" --context "${CONTEXT}" -o json 2>/dev/null \
    | jq '{items: [.items[] | select(.metadata.name | test("seaweed"; "i"))]}' || echo '{"items":[]}')
  dep_json=$("${KUBECTL}" get deployment -n "${NAMESPACE}" --context "${CONTEXT}" -l "$base_selector" -o json 2>/dev/null \
    || "${KUBECTL}" get deployment -n "${NAMESPACE}" --context "${CONTEXT}" -o json 2>/dev/null \
    | jq '{items: [.items[] | select(.metadata.name | test("seaweed"; "i"))]}' || echo '{"items":[]}')
  svc_json=$("${KUBECTL}" get svc -n "${NAMESPACE}" --context "${CONTEXT}" -o json 2>/dev/null \
    | jq '{items: [.items[] | select(.metadata.name | test("seaweed"; "i"))]}' || echo '{"items":[]}')
  pvc_json=$("${KUBECTL}" get pvc -n "${NAMESPACE}" --context "${CONTEXT}" -o json 2>/dev/null \
    | jq '{items: [.items[] | select(.metadata.name | test("seaweed"; "i"))]}' || echo '{"items":[]}')

  jq -n \
    --arg release "$release" \
    --arg namespace "${NAMESPACE}" \
    --argjson statefulsets "$sts_json" \
    --argjson deployments "$dep_json" \
    --argjson services "$svc_json" \
    --argjson pvcs "$pvc_json" \
    '{
      release: $release,
      namespace: $namespace,
      statefulsets: [$statefulsets.items[] | {name: .metadata.name, component: (.metadata.labels["app.kubernetes.io/component"] // "unknown"), replicas: (.spec.replicas // 0), ready: (.status.readyReplicas // 0)}],
      deployments: [$deployments.items[] | {name: .metadata.name, component: (.metadata.labels["app.kubernetes.io/component"] // "unknown"), replicas: (.spec.replicas // 0), ready: (.status.readyReplicas // 0)}],
      services: [$services.items[] | {name: .metadata.name, type: .spec.type, ports: [.spec.ports[]? | {port: .port, name: .name}]}],
      pvcs: [$pvcs.items[] | {name: .metadata.name, phase: (.status.phase // "Unknown"), capacity: (.status.capacity.storage // "unknown")}]
    }'
}

swf_seaweed_workloads() {
  swf_discover_components | jq -c '.statefulsets[], .deployments[]'
}

swf_parse_s3_credentials() {
  if [[ -z "${seaweedfs_s3_credentials:-}" && -z "${SEAWEEDFS_S3_CREDENTIALS:-}" ]]; then
    return 0
  fi
  local raw="${seaweedfs_s3_credentials:-${SEAWEEDFS_S3_CREDENTIALS:-}}"
  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
  AWS_ACCESS_KEY_ID=$(echo "$raw" | jq -r '.AWS_ACCESS_KEY_ID // .access_key // .accessKey // empty')
  AWS_SECRET_ACCESS_KEY=$(echo "$raw" | jq -r '.AWS_SECRET_ACCESS_KEY // .secret_key // .secretKey // empty')
}

swf_s3_endpoint_url() {
  if [[ -n "${SEAWEEDFS_S3_ENDPOINT:-}" ]]; then
    echo "${SEAWEEDFS_S3_ENDPOINT}"
    return 0
  fi
  local svc
  svc=$("${KUBECTL}" get svc -n "${NAMESPACE}" --context "${CONTEXT}" -o json 2>/dev/null \
    | jq -r '.items[] | select(.metadata.name | test("seaweed.*(filer|s3)"; "i")) | .metadata.name' | head -n1 || true)
  if [[ -n "$svc" ]]; then
    echo "http://${svc}.${NAMESPACE}.svc.cluster.local:${S3_PORT}"
    return 0
  fi
  local pod
  pod=$(swf_find_pod "filer")
  if [[ -n "$pod" ]]; then
    echo "http://127.0.0.1:${S3_PORT}"
  fi
}
