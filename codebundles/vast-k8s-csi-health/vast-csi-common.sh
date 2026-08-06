#!/usr/bin/env bash
# Shared helpers for VAST CSI health scripts.
set -euo pipefail

KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
VAST_CSI_PROVISIONER="${VAST_CSI_PROVISIONER:-csi.vastdata.com}"
VAST_CSI_PROVISIONER_LEGACY="${VAST_CSI_PROVISIONER_LEGACY:-kubernetes.io/csi/csi.vastdata.com}"

k8s() {
  "${KUBECTL}" "$@" --context "${CONTEXT}"
}

is_vast_storage_class() {
  local sc="$1"
  [[ -z "$sc" || "$sc" == "null" ]] && return 1
  local prov
  prov=$(k8s get storageclass "$sc" -o jsonpath='{.provisioner}' 2>/dev/null || true)
  [[ "$prov" == "$VAST_CSI_PROVISIONER" || "$prov" == "$VAST_CSI_PROVISIONER_LEGACY" ]] && return 0
  [[ "$sc" =~ [Vv][Aa][Ss][Tt] ]] && return 0
  return 1
}

is_vast_pv() {
  local pv="$1"
  [[ -z "$pv" || "$pv" == "null" ]] && return 1
  local driver
  driver=$(k8s get pv "$pv" -o jsonpath='{.spec.csi.driver}' 2>/dev/null || true)
  [[ "$driver" == "$VAST_CSI_PROVISIONER" ]] && return 0
  return 1
}

is_vast_pvc_json() {
  local pvc_json="$1"
  local sc pv
  sc=$(echo "$pvc_json" | jq -r '.spec.storageClassName // empty')
  pv=$(echo "$pvc_json" | jq -r '.spec.volumeName // empty')
  if is_vast_storage_class "$sc"; then
    return 0
  fi
  if is_vast_pv "$pv"; then
    return 0
  fi
  return 1
}

list_vast_pvcs_json() {
  local ns="${1:?namespace required}"
  k8s get pvc -n "$ns" -o json 2>/dev/null | jq -c --arg ns "$ns" '
    .items // [] | map(select(
      (.spec.storageClassName // "" | test("vast"; "i")) or
      (.metadata.annotations["volume.beta.kubernetes.io/storage-provisioner"]? // "" | test("vast"; "i"))
    )) | {items: .}
  ' || echo '{"items":[]}'
}

find_csi_node_pods() {
  local ns="${CSI_NAMESPACE:?Must set CSI_NAMESPACE}"
  k8s get pods -n "$ns" -o json 2>/dev/null | jq -c '
    {items: [.items[] | select(
      (.metadata.labels["app.kubernetes.io/component"]? // "" | test("node"; "i")) or
      (.metadata.labels["app"]? // "" | test("vast.*node|node"; "i")) or
      (.metadata.name | test("vast.*node|node"; "i"))
    )]}
  ' || echo '{"items":[]}'
}

find_csi_controller_pods() {
  local ns="${CSI_NAMESPACE:?Must set CSI_NAMESPACE}"
  k8s get pods -n "$ns" -o json 2>/dev/null | jq -c '
    {items: [.items[] | select(
      (.metadata.labels["app.kubernetes.io/component"]? // "" | test("controller"; "i")) or
      (.metadata.labels["app"]? // "" | test("vast.*controller|controller"; "i")) or
      (.metadata.name | test("vast.*controller|controller"; "i"))
    )]}
  ' || echo '{"items":[]}'
}

curl_pod_metrics() {
  local pod="$1"
  local ns="$2"
  local port="${3:?port required}"
  k8s exec -n "$ns" "$pod" -- sh -c "wget -qO- http://127.0.0.1:${port}/metrics 2>/dev/null || curl -sf http://127.0.0.1:${port}/metrics 2>/dev/null" 2>/dev/null || true
}

curl_service_metrics() {
  local svc="$1"
  local ns="$2"
  local port="$3"
  k8s run "vast-metrics-probe-$$" -n "$ns" --rm -i --restart=Never \
    --image=curlimages/curl:8.5.0 --command -- \
    curl -sf --max-time 15 "http://${svc}.${ns}.svc.cluster.local:${port}/metrics" 2>/dev/null || true
}

find_metrics_services() {
  local ns="${CSI_NAMESPACE:?Must set CSI_NAMESPACE}"
  k8s get svc -n "$ns" -o json 2>/dev/null | jq -c '
    [.items[] | select(.metadata.name | test("metrics|vast"; "i")) | {
      name: .metadata.name,
      ports: [.spec.ports[]? | {name: (.name // ""), port: .port}]
    }]
  ' || echo '[]'
}

append_issue() {
  local issues_json="$1"
  local title="$2"
  local details="$3"
  local severity="$4"
  local next_steps="$5"
  echo "$issues_json" | jq \
    --arg title "$title" \
    --arg details "$details" \
    --argjson severity "$severity" \
    --arg next_steps "$next_steps" \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]'
}

write_issues() {
  local file="$1"
  local issues_json="$2"
  echo "$issues_json" >"$file"
}
