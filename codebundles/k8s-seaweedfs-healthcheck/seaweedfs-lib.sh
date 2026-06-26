#!/usr/bin/env bash
# Shared helpers for SeaweedFS healthcheck scripts.
# shellcheck disable=SC2034
set -euo pipefail

KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
MASTER_PORT="${SEAWEEDFS_MASTER_PORT:-9333}"
VOLUME_PORT="${SEAWEEDFS_VOLUME_PORT:-8080}"
FILER_PORT="${SEAWEEDFS_FILER_PORT:-8888}"
S3_PORT="${SEAWEEDFS_S3_PORT:-8333}"
SEAWEEDFS_CHART_PREFIX="${SEAWEEDFS_CHART_PREFIX:-seaweedfs}"

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

# jq filter args: chart_prefix (e.g. seaweedfs-), chart_exact, release_name
swf_jq_filter_args() {
  jq -n \
    --arg chart_prefix "${SEAWEEDFS_CHART_PREFIX}-" \
    --arg chart_exact "${SEAWEEDFS_CHART:-}" \
    --arg release "${SEAWEEDFS_RELEASE_NAME:-}" \
    '{chart_prefix: $chart_prefix, chart_exact: $chart_exact, release: $release}'
}

# Returns true when labels belong to the SeaweedFS Helm chart (subchart or standalone).
swf_labels_match() {
  local labels_json="$1"
  local filter_args
  filter_args=$(swf_jq_filter_args)
  echo "$labels_json" | jq -e --argjson f "$filter_args" '
    (.["app.kubernetes.io/name"]? == "seaweedfs") and
    (
      if ($f.chart_exact | length) > 0 then
        (.["helm.sh/chart"]? == $f.chart_exact)
      elif (.["helm.sh/chart"]? // "" | length) > 0 then
        (.["helm.sh/chart"] | startswith($f.chart_prefix))
      else
        true
      end
    ) and
    (
      if ($f.release | length) > 0 then
        (.["app.kubernetes.io/instance"]? == $f.release)
      else
        true
      end
    )
  ' >/dev/null 2>&1
}

swf_filter_resource_list() {
  local json="$1"
  local filter_args
  filter_args=$(swf_jq_filter_args)
  echo "$json" | jq --argjson f "$filter_args" '
    .items |= map(
      select(
        (.metadata.labels["app.kubernetes.io/name"]? == "seaweedfs") and
        (
          if ($f.chart_exact | length) > 0 then
            (.metadata.labels["helm.sh/chart"]? == $f.chart_exact)
          elif (.metadata.labels["helm.sh/chart"]? // "" | length) > 0 then
            (.metadata.labels["helm.sh/chart"] | startswith($f.chart_prefix))
          else
            (.metadata.name | test("seaweedfs"; "i"))
          end
        ) and
        (
          if ($f.release | length) > 0 then
            (.metadata.labels["app.kubernetes.io/instance"]? == $f.release)
          else
            true
          end
        )
      )
    )
  '
}

swf_filter_service_list() {
  local json="$1"
  local filter_args
  filter_args=$(swf_jq_filter_args)
  echo "$json" | jq --argjson f "$filter_args" '
    .items |= map(
      select(
        (
          (.metadata.labels["app.kubernetes.io/name"]? == "seaweedfs") and
          (
            if ($f.chart_exact | length) > 0 then
              (.metadata.labels["helm.sh/chart"]? == $f.chart_exact)
            elif (.metadata.labels["helm.sh/chart"]? // "" | length) > 0 then
              (.metadata.labels["helm.sh/chart"] | startswith($f.chart_prefix))
            else
              false
            end
          )
        ) or (
          (.metadata.name | test("seaweedfs"; "i")) and
          (
            if ($f.release | length) > 0 then
              (.metadata.labels["app.kubernetes.io/instance"]? == $f.release)
            else
              true
            end
          )
        )
      )
    )
  '
}

swf_filter_pvc_list() {
  local json="$1"
  local filter_args
  filter_args=$(swf_jq_filter_args)
  echo "$json" | jq --argjson f "$filter_args" '
    .items |= map(
      select(
        (.metadata.labels["app.kubernetes.io/name"]? == "seaweedfs") and
        (
          if ($f.release | length) > 0 then
            (.metadata.labels["app.kubernetes.io/instance"]? == $f.release)
          else
            true
          end
        ) and
        (
          (.metadata.name | test("seaweedfs"; "i")) or
          (.metadata.labels["app.kubernetes.io/component"]? != null)
        )
      )
    )
  '
}

swf_resolve_release_name() {
  if [[ -n "${SEAWEEDFS_RELEASE_NAME:-}" ]]; then
    echo "${SEAWEEDFS_RELEASE_NAME}"
    return 0
  fi
  local raw filtered
  raw=$("${KUBECTL}" get statefulset,deployment -n "${NAMESPACE}" --context "${CONTEXT}" \
    -l 'app.kubernetes.io/name=seaweedfs' -o json 2>/dev/null || echo '{"items":[]}')
  filtered=$(swf_filter_resource_list "$raw")
  local from_label
  from_label=$(echo "$filtered" | jq -r '.items[0].metadata.labels["app.kubernetes.io/instance"] // empty' 2>/dev/null || true)
  if [[ -n "$from_label" ]]; then
    echo "$from_label"
    return 0
  fi
  echo ""
}

swf_resolve_chart_label() {
  if [[ -n "${SEAWEEDFS_CHART:-}" ]]; then
    echo "${SEAWEEDFS_CHART}"
    return 0
  fi
  local raw filtered
  raw=$("${KUBECTL}" get statefulset -n "${NAMESPACE}" --context "${CONTEXT}" \
    -l 'app.kubernetes.io/name=seaweedfs,app.kubernetes.io/component=master' -o json 2>/dev/null || echo '{"items":[]}')
  filtered=$(swf_filter_resource_list "$raw")
  echo "$filtered" | jq -r '.items[0].metadata.labels["helm.sh/chart"] // empty' 2>/dev/null || true
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

swf_filter_pods_json() {
  local json="$1"
  swf_filter_resource_list "$json" | jq 'if .items|type == "array" then . else {items: .items} end'
}

swf_find_pod() {
  local component="$1"
  local selector pod raw filtered
  selector=$(swf_label_selector "$component")
  pod=$("${KUBECTL}" get pods -n "${NAMESPACE}" --context "${CONTEXT}" \
    -l "$selector" --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "$pod" ]]; then
    echo "$pod"
    return 0
  fi
  raw=$("${KUBECTL}" get pods -n "${NAMESPACE}" --context "${CONTEXT}" -o json 2>/dev/null || echo '{"items":[]}')
  filtered=$(swf_filter_resource_list "$raw")
  pod=$(echo "$filtered" | jq -r --arg c "$component" \
    '.items[] | select(.status.phase=="Running") | select(.metadata.labels["app.kubernetes.io/component"]? == $c) | .metadata.name' \
    | head -n1 || true)
  if [[ -n "$pod" ]]; then
    echo "$pod"
    return 0
  fi
  echo "$filtered" | jq -r --arg c "$component" \
    '.items[] | select(.status.phase=="Running") | select(.metadata.name | test($c; "i")) | .metadata.name' \
    | head -n1 || true
}

swf_count_running_pods() {
  local component="${1:-}"
  local selector raw filtered count
  if [[ -n "$component" ]]; then
    selector=$(swf_label_selector "$component")
    count=$("${KUBECTL}" get pods -n "${NAMESPACE}" --context "${CONTEXT}" \
      -l "$selector" --field-selector=status.phase=Running -o json 2>/dev/null \
      | jq '.items | length' || echo 0)
    if [[ "$count" =~ ^[0-9]+$ ]] && [[ "$count" -gt 0 ]]; then
      echo "$count"
      return 0
    fi
  fi
  raw=$("${KUBECTL}" get pods -n "${NAMESPACE}" --context "${CONTEXT}" -o json 2>/dev/null || echo '{"items":[]}')
  filtered=$(swf_filter_resource_list "$raw")
  if [[ -n "$component" ]]; then
    echo "$filtered" | jq --arg c "$component" \
      '[.items[] | select(.status.phase=="Running") | select(.metadata.labels["app.kubernetes.io/component"]? == $c)] | length'
  else
    echo "$filtered" | jq '[.items[] | select(.status.phase=="Running")] | length'
  fi
}

swf_pod_http() {
  local pod="$1"
  local port="$2"
  local path="$3"
  [[ -z "$pod" ]] && return 1
  "${KUBECTL}" exec -n "${NAMESPACE}" --context "${CONTEXT}" "$pod" -- \
    sh -c "wget -qO- 'http://127.0.0.1:${port}${path}' 2>/dev/null || curl -sf 'http://127.0.0.1:${port}${path}' 2>/dev/null" 2>/dev/null
}

# True when the pod accepts HTTP on port (any status, including 403).
swf_pod_http_listening() {
  local pod="$1"
  local port="$2"
  local path="${3:-/}"
  local out
  [[ -z "$pod" ]] && return 1
  out=$("${KUBECTL}" exec -n "${NAMESPACE}" --context "${CONTEXT}" "$pod" -- \
    wget -S -O /dev/null "http://127.0.0.1:${port}${path}" 2>&1 || true)
  if echo "$out" | grep -qiE 'HTTP/1\.[0-9]+ [0-9]'; then
    return 0
  fi
  out=$("${KUBECTL}" exec -n "${NAMESPACE}" --context "${CONTEXT}" "$pod" -- \
    curl -sI "http://127.0.0.1:${port}${path}" 2>/dev/null || true)
  echo "$out" | grep -qiE 'HTTP/'
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
  local release chart
  release=$(swf_resolve_release_name)
  chart=$(swf_resolve_chart_label)

  local sts_json dep_json svc_json pvc_json sts_raw dep_raw svc_raw pvc_raw
  sts_raw=$("${KUBECTL}" get statefulset -n "${NAMESPACE}" --context "${CONTEXT}" \
    -l 'app.kubernetes.io/name=seaweedfs' -o json 2>/dev/null || echo '{"items":[]}')
  dep_raw=$("${KUBECTL}" get deployment -n "${NAMESPACE}" --context "${CONTEXT}" \
    -l 'app.kubernetes.io/name=seaweedfs' -o json 2>/dev/null || echo '{"items":[]}')
  svc_raw=$("${KUBECTL}" get svc -n "${NAMESPACE}" --context "${CONTEXT}" \
    -l 'app.kubernetes.io/name=seaweedfs' -o json 2>/dev/null || echo '{"items":[]}')
  pvc_raw=$("${KUBECTL}" get pvc -n "${NAMESPACE}" --context "${CONTEXT}" \
    -l 'app.kubernetes.io/name=seaweedfs' -o json 2>/dev/null || echo '{"items":[]}')

  sts_json=$(swf_filter_resource_list "$sts_raw")
  dep_json=$(swf_filter_resource_list "$dep_raw")
  svc_json=$(swf_filter_service_list "$svc_raw")
  pvc_json=$(swf_filter_pvc_list "$pvc_raw")

  jq -n \
    --arg release "$release" \
    --arg chart "$chart" \
    --arg namespace "${NAMESPACE}" \
    --argjson statefulsets "$sts_json" \
    --argjson deployments "$dep_json" \
    --argjson services "$svc_json" \
    --argjson pvcs "$pvc_json" \
    '{
      release: $release,
      chart: $chart,
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

swf_find_s3_probe_pod() {
  local pod
  pod=$(swf_find_pod "s3")
  if [[ -n "$pod" ]]; then
    echo "$pod"
    return 0
  fi
  swf_find_pod "filer"
}

swf_s3_endpoint_url() {
  if [[ -n "${SEAWEEDFS_S3_ENDPOINT:-}" ]]; then
    echo "${SEAWEEDFS_S3_ENDPOINT}"
    return 0
  fi
  local map_json svc_name
  map_json=$(swf_discover_components)
  svc_name=$(echo "$map_json" | jq -r '
    [.services[] | select(.name | test("s3"; "i"))][0].name // empty
  ')
  if [[ -n "$svc_name" ]]; then
    echo "http://${svc_name}.${NAMESPACE}.svc.cluster.local:${S3_PORT}"
    return 0
  fi
  svc_name=$(echo "$map_json" | jq -r '
    [.services[] | select(.name | test("seaweedfs"; "i")) | select(.ports[]?.port == 8333)][0].name // empty
  ')
  if [[ -n "$svc_name" ]]; then
    echo "http://${svc_name}.${NAMESPACE}.svc.cluster.local:${S3_PORT}"
    return 0
  fi
  local pod
  pod=$(swf_find_s3_probe_pod)
  if [[ -n "$pod" ]]; then
    echo "http://127.0.0.1:${S3_PORT}"
  fi
}

METRICS_PORT="${SEAWEEDFS_METRICS_PORT:-9327}"

swf_get_filtered_workloads_raw() {
  local sts_raw dep_raw
  sts_raw=$("${KUBECTL}" get statefulset -n "${NAMESPACE}" --context "${CONTEXT}" \
    -l 'app.kubernetes.io/name=seaweedfs' -o json 2>/dev/null || echo '{"items":[]}')
  dep_raw=$("${KUBECTL}" get deployment -n "${NAMESPACE}" --context "${CONTEXT}" \
    -l 'app.kubernetes.io/name=seaweedfs' -o json 2>/dev/null || echo '{"items":[]}')
  sts_raw=$(swf_filter_resource_list "$sts_raw")
  dep_raw=$(swf_filter_resource_list "$dep_raw")
  jq -n --argjson sts "$sts_raw" --argjson dep "$dep_raw" \
    '{items: (($sts.items // []) + ($dep.items // []))}'
}

swf_weed_command_text() {
  local workload_json="$1"
  echo "$workload_json" | jq -r '
    (.spec.template.spec.containers[0].command // []) | join(" ")
  ' | tr '\\' ' '
}

swf_fetch_pod_metrics() {
  local pod="$1"
  local port="${2:-9327}"
  [[ -z "$pod" ]] && return 1
  swf_pod_http "$pod" "$port" "/metrics"
}

swf_chart_version() {
  local chart="${SEAWEEDFS_CHART:-}"
  if [[ -z "$chart" ]]; then
    chart=$(swf_resolve_chart_label)
  fi
  echo "$chart" | sed -E 's/^seaweedfs-//; s/_.*$//'
}

swf_replication_min_volumes() {
  local repl="$1"
  local extras=0
  local i c
  for ((i = 0; i < ${#repl}; i++)); do
    c="${repl:$i:1}"
    if [[ "$c" =~ [1-9] ]]; then
      extras=$((extras + 1))
    fi
  done
  echo $((1 + extras))
}

swf_metric_gauge_value() {
  local metrics="$1"
  local name="$2"
  echo "$metrics" | awk -v n="$name" '$1 ~ "^" n "\\{" || $1 == n {print $2; exit}'
}

swf_metric_sum_matching() {
  local metrics="$1"
  local pattern="$2"
  echo "$metrics" | awk -v pat="$pattern" '$1 ~ pat {sum += $2} END {print sum+0}'
}

swf_capacity_snapshot_path() {
  local release
  release=$(swf_resolve_release_name)
  local base="${CODEBUNDLE_TEMP_DIR:-/tmp}"
  echo "${base}/seaweedfs_capacity_${NAMESPACE}_${release:-all}.json"
}
