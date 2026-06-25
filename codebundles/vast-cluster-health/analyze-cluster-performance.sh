#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Reviews cluster-wide protocol performance (NFS, block, S3) for IO stalls.
# -----------------------------------------------------------------------------

OUTPUT_FILE="cluster_performance_output.json"
REPORT_FILE="cluster_performance_report.txt"

source "$(dirname "$0")/vast-vms-common.sh"

PERFORMANCE_DROP_THRESHOLD="${PERFORMANCE_DROP_THRESHOLD:-90}"
MIN_BASELINE_IOPS="${MIN_BASELINE_IOPS:-100}"

issues_json="$(vast_init_issues)"
report="Cluster protocol performance for \`${VAST_CLUSTER_NAME}\`\n"

if ! _vast_load_credentials; then
  issues_json="$(vast_api_error_issue "$issues_json" "credentials" "missing vast_vms_credentials")"
  echo "$issues_json" > "$OUTPUT_FILE"
  echo -e "$report" > "$REPORT_FILE"
  exit 0
fi

metrics_text=""
if ! metrics_text="$(vast_prometheus_get "basic_no_views" 2>metrics.err || vast_prometheus_get "" 2>>metrics.err)"; then
  err_msg="$(cat metrics.err 2>/dev/null || echo unknown)"
  report+="Warning: performance metrics unavailable: ${err_msg}\n"
  echo "$issues_json" > "$OUTPUT_FILE"
  echo -e "$report" > "$REPORT_FILE"
  echo -e "$report"
  exit 0
fi
rm -f metrics.err

python3 - <<'PY' "$metrics_text" "$PERFORMANCE_DROP_THRESHOLD" "$MIN_BASELINE_IOPS" "$VAST_CLUSTER_NAME" > perf_analysis.json
import json, re, sys

metrics_text, drop_threshold, min_baseline, cluster = sys.argv[1:5]
drop_threshold = float(drop_threshold)
min_baseline = float(min_baseline)

protocol_patterns = {
    "NFS": re.compile(r"(nfs|NFS).*iops", re.I),
    "Block": re.compile(r"(block|BLOCK).*iops", re.I),
    "S3": re.compile(r"(s3|S3).*iops", re.I),
}

values = {}
for line in metrics_text.splitlines():
    if line.startswith("#") or not line.strip():
        continue
    parts = line.split()
    if len(parts) < 2:
        continue
    name, val = parts[0], parts[1]
    try:
        num = float(val)
    except ValueError:
        continue
    for proto, pat in protocol_patterns.items():
        if pat.search(name):
            values.setdefault(proto, []).append(num)

issues = []
report_lines = []
for proto, nums in values.items():
    total = sum(nums)
    report_lines.append(f"{proto} aggregate IOPS sample total={total:.0f} from {len(nums)} metric(s)")
    if total >= min_baseline and total < min_baseline * (drop_threshold / 100.0):
        issues.append({
            "title": f"Abnormally Low {proto} IOPS on VAST Cluster `{cluster}`",
            "details": f"{proto} aggregate IOPS ({total:.0f}) is below {drop_threshold}% of baseline threshold ({min_baseline:.0f}).",
            "severity": 3,
            "next_steps": f"Check {proto} client connectivity, VIP health, and recent cluster events; compare with historical dashboards",
        })

latency_hits = []
for line in metrics_text.splitlines():
    if line.startswith("#"):
        continue
    if re.search(r"latency", line, re.I):
        parts = line.split()
        if len(parts) >= 2:
            try:
                val = float(parts[1])
            except ValueError:
                continue
            if val > 100:  # ms threshold for cluster-wide latency gauges
                latency_hits.append(f"{parts[0]}={val}")

if latency_hits:
    issues.append({
        "title": f"Elevated Cluster Protocol Latency on VAST Cluster `{cluster}`",
        "details": "High latency metrics detected:\n" + "\n".join(latency_hits[:10]),
        "severity": 3,
        "next_steps": "Inspect network path, DNode load, and QoS policies; correlate with tenant-level metrics",
    })
    report_lines.append(f"High latency metrics: {len(latency_hits)}")

if not values and not latency_hits:
    report_lines.append("No recognizable protocol IOPS/latency metrics in exporter output (graceful skip).")

print(json.dumps({"issues": issues, "report": report_lines}))
PY

mapfile -t report_lines < <(jq -r '.report[]' perf_analysis.json)
for line in "${report_lines[@]:-}"; do
  report+="${line}\n"
done

while IFS= read -r issue; do
  [[ -z "$issue" || "$issue" == "null" ]] && continue
  title="$(echo "$issue" | jq -r '.title')"
  details="$(echo "$issue" | jq -r '.details')"
  severity="$(echo "$issue" | jq -r '.severity')"
  next_steps="$(echo "$issue" | jq -r '.next_steps')"
  issues_json="$(vast_append_issue "$issues_json" "$title" "$details" "$severity" "$next_steps")"
done < <(jq -c '.issues[]?' perf_analysis.json 2>/dev/null || true)

rm -f perf_analysis.json
echo "$issues_json" > "$OUTPUT_FILE"
echo -e "$report" > "$REPORT_FILE"
echo -e "$report"
echo "Analysis completed. Results saved to $OUTPUT_FILE"
