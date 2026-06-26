#!/usr/bin/env bash
set -euo pipefail
# Audits SeaweedFS Helm/Kubernetes workload configuration (args, env, mounts, replication).
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

OUTPUT_FILE="volume_config_issues.json"
CONFIG_SNAPSHOT_FILE="${CONFIG_SNAPSHOT_FILE:-seaweedfs_config_snapshot.json}"
# shellcheck disable=SC1091
source seaweedfs-lib.sh

print_report() {
  echo "=== SeaweedFS volume configuration audit ==="
  [[ -f "$CONFIG_SNAPSHOT_FILE" ]] && jq '.' "$CONFIG_SNAPSHOT_FILE" 2>/dev/null || true
  jq -r '.[] | "  - [sev=\(.severity)] \(.title)"' "$OUTPUT_FILE" 2>/dev/null || true
}
trap print_report EXIT

map_json=$(swf_discover_components)
workloads=$(swf_get_filtered_workloads_raw)
echo "$workloads" | jq --argjson map "$map_json" '
  {
    release: $map.release,
    chart: $map.chart,
    workloads: [
      .items[] | {
        kind: .kind,
        name: .metadata.name,
        component: (.metadata.labels["app.kubernetes.io/component"] // "unknown"),
        replicas: (.spec.replicas // 1),
        command: ((.spec.template.spec.containers[0].command // []) | join(" ") | gsub("\\\\ "; " ")),
        env: [.spec.template.spec.containers[0].env[]? | {name, value: (.value // "")}],
        volumeMounts: [.spec.template.spec.containers[0].volumeMounts[]? | .mountPath],
        volumes: [.spec.template.spec.volumes[]? | {name, claim: (.persistentVolumeClaim.claimName // "")}]
      }
    ]
  }
' >"$CONFIG_SNAPSHOT_FILE"

default_replication=""
master_replicas=0
volume_replicas=0
volume_max=""
volume_dirs=()
master_peers=""

while IFS= read -r wl; do
  [[ -z "$wl" ]] && continue
  component=$(echo "$wl" | jq -r '.component')
  name=$(echo "$wl" | jq -r '.name')
  cmd=$(echo "$wl" | jq -r '.command')
  replicas=$(echo "$wl" | jq -r '.replicas')

  case "$component" in
    master)
      master_replicas=$replicas
      if echo "$cmd" | grep -qE '\-defaultReplication='; then
        default_replication=$(echo "$cmd" | sed -n 's/.*-defaultReplication=\([^ ]*\).*/\1/p')
      fi
      if echo "$cmd" | grep -qE '\-peers='; then
        master_peers=$(echo "$cmd" | sed -n 's/.*-peers=\([^ ]*\).*/\1/p')
        peer_count=$(echo "$master_peers" | tr ',' '\n' | grep -c . || echo 0)
        if [[ "$peer_count" =~ ^[0-9]+$ ]] && [[ "$replicas" =~ ^[0-9]+$ ]] && [[ "$peer_count" -ne "$replicas" ]]; then
          swf_add_issue \
            "SeaweedFS master peer list count (${peer_count}) differs from StatefulSet replicas (${replicas})" \
            "Workload \`${name}\`, peers=${master_peers}" \
            2 \
            "Align master.peers in Helm values with master.replicas for HA."
        fi
      fi
      mdir=$(echo "$cmd" | sed -n 's/.*-mdir=\([^ ]*\).*/\1/p')
      if [[ -n "$mdir" ]]; then
        mounted=$(echo "$wl" | jq -r --arg p "$mdir" '.volumeMounts[]? | select(. == $p) // empty')
        if [[ -z "$mounted" ]]; then
          swf_add_issue \
            "SeaweedFS master metadata dir \`${mdir}\` is not mounted in \`${name}\`" \
            "Command declares -mdir but no matching volumeMount." \
            2 \
            "Add a PVC/volumeMount for ${mdir} or fix Helm master.data persistence settings."
        fi
      fi
      ;;
    volume)
      volume_replicas=$replicas
      if echo "$cmd" | grep -qE '\-max='; then
        volume_max=$(echo "$cmd" | sed -n 's/.*-max=\([^ ]*\).*/\1/p')
      fi
      while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        volume_dirs+=("$dir")
        mounted=$(echo "$wl" | jq -r --arg p "$dir" '.volumeMounts[]? | select(. == $p) // empty')
        if [[ -z "$mounted" ]]; then
          swf_add_issue \
            "SeaweedFS volume data dir \`${dir}\` is not mounted in \`${name}\`" \
            "Command declares -dir=${dir} without a matching volumeMount." \
            2 \
            "Verify volume.dataDirs and persistence in Helm values."
        fi
      done < <(echo "$cmd" | grep -oE '\-dir=[^ ]+' | sed 's/-dir=//' || true)
      ;;
    filer)
      master_env=$(echo "$wl" | jq -r '.env[] | select(.name=="WEED_CLUSTER_SW_MASTER") | .value // empty')
      if [[ -z "$master_env" ]]; then
        swf_add_issue \
          "SeaweedFS filer \`${name}\` missing WEED_CLUSTER_SW_MASTER env" \
          "Filer may not discover the master service in-cluster." \
            3 \
          "Set filer cluster master address in Helm values."
      fi
      ;;
  esac
done < <(jq -c '.workloads[]' "$CONFIG_SNAPSHOT_FILE")

if [[ -n "$default_replication" ]]; then
  min_vols=$(swf_replication_min_volumes "$default_replication")
  if [[ "$volume_replicas" =~ ^[0-9]+$ ]] && [[ "$min_vols" =~ ^[0-9]+$ ]] && [[ "$volume_replicas" -lt "$min_vols" ]]; then
    swf_add_issue \
      "SeaweedFS defaultReplication \`${default_replication}\` requires at least ${min_vols} volume server(s)" \
      "Running volume replicas=${volume_replicas}, chart defaultReplication=${default_replication}" \
      2 \
      "Increase volume.replicas or lower defaultReplication in Helm values."
  fi
else
  swf_add_issue \
    "SeaweedFS master defaultReplication not found in workload command" \
    "Could not parse -defaultReplication from master container command." \
    3 \
    "Confirm master.extraArgs or chart defaults set defaultReplication explicitly."
fi

if [[ -n "$volume_max" ]] && [[ "$volume_max" =~ ^[0-9]+$ ]] && [[ "$volume_max" -lt 10 ]]; then
  swf_add_issue \
    "SeaweedFS volume server -max=${volume_max} is low for production" \
    "Each volume pod is capped at ${volume_max} volumes." \
    3 \
    "Raise volume.maxVolumes in Helm values if slot exhaustion is frequent."
fi

if [[ "$master_replicas" -eq 1 && -n "$master_peers" ]]; then
  swf_add_issue \
    "SeaweedFS master runs single replica with explicit peer bootstrap" \
    "Single master with -peers configured; verify this matches intended topology." \
    3 \
    "Use master.replicas=3 for HA or remove redundant peer wiring on single-node installs."
fi

swf_write_issues "$OUTPUT_FILE"
