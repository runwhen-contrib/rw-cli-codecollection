#!/usr/bin/env bash
set -euo pipefail
set -x
# Queries SeaweedFS master via weed shell s3.bucket.list for per-bucket storage, quota, and usage.
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

OUTPUT_FILE="bucket_usage_issues.json"
QUOTA_WARN_PCT="${QUOTA_WARN_PCT:-80}"
QUOTA_CRIT_PCT="${QUOTA_CRIT_PCT:-95}"
MAX_BUCKETS_SHOWN="${MAX_BUCKETS_SHOWN:-20}"
# shellcheck disable=SC1091
source seaweedfs-lib.sh

fmt_size() {
  local bytes="$1"
  local v="$bytes"
  if [[ "$v" -lt 1024 ]]; then
    echo "${v}B"
    return
  fi
  local u="KB"
  v=$(awk "BEGIN {printf \"%.1f\", $v/1024}")
  if [[ "$(echo "$v >= 1024" | bc -l 2>/dev/null || echo 0)" == "1" ]]; then
    v=$(awk "BEGIN {printf \"%.1f\", $v/1024}")
    u="MB"
  fi
  if [[ "$(echo "$v >= 1024" | bc -l 2>/dev/null || echo 0)" == "1" ]]; then
    v=$(awk "BEGIN {printf \"%.1f\", $v/1024}")
    u="GB"
  fi
  if [[ "$(echo "$v >= 1024" | bc -l 2>/dev/null || echo 0)" == "1" ]]; then
    v=$(awk "BEGIN {printf \"%.1f\", $v/1024}")
    u="TB"
  fi
  echo "${v}${u}"
}

print_report() {
  { set +x; } 2>/dev/null || true
  local count
  count=$(jq '. | length' "$OUTPUT_FILE" 2>/dev/null || echo 0)
  if [[ "$count" -gt 0 ]]; then
    echo "=== SeaweedFS bucket usage ==="
    jq -r '.[] | "  - [sev=\(.severity)] \(.title)"' "$OUTPUT_FILE" 2>/dev/null || true
  fi
}
trap print_report EXIT

master_pod=$(swf_find_pod "master")
if [[ -z "$master_pod" ]]; then
  swf_add_issue \
    "No running SeaweedFS master pod found in \`${NAMESPACE}\`" \
    "Bucket usage cannot be queried without a running master pod." \
    3 \
    "Verify master StatefulSet is deployed and running in namespace ${NAMESPACE}."
  swf_write_issues "$OUTPUT_FILE"
  exit 0
fi

echo "=== SeaweedFS Bucket Usage — ${NAMESPACE} ==="
echo "  Master pod: ${master_pod}"
echo ""

bucket_output=$("${KUBECTL}" exec -n "${NAMESPACE}" --context "${CONTEXT}" "$master_pod" -- \
  sh -c "echo 's3.bucket.list' | weed shell -master=localhost:9333" 2>/dev/null || true)

if [[ -z "$bucket_output" ]]; then
  swf_add_issue \
    "Failed to query SeaweedFS bucket list from \`${master_pod}\`" \
    "weed shell s3.bucket.list returned no output. The master may be unreachable or the shell is not available." \
    3 \
    "Check master logs: kubectl logs ${master_pod} -n ${NAMESPACE} --context ${CONTEXT}. Verify weed shell is functional."
  swf_write_issues "$OUTPUT_FILE"
  exit 0
fi

# Parse bucket lines: skip header/banner lines, keep lines that look like bucket entries
declare -a bucket_names bucket_sizes bucket_logicals bucket_chunks bucket_quotas bucket_usages

while IFS= read -r line; do
  line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [[ -z "$line" ]] && continue
  [[ "$line" =~ ^[Bb]ucket ]] && continue
  [[ "$line" =~ ^--- ]] && continue
  [[ "$line" =~ seaweedfs ]] && continue
  [[ "$line" =~ localhost ]] && continue
  [[ "$line" =~ "type \"help\"" ]] && continue
  [[ "$line" =~ ^\> ]] && line="${line#> }"

  bucket_name=$(echo "$line" | awk '{print $1}')
  if [[ -z "$bucket_name" || "$bucket_name" == ">" || "$bucket_name" == "Bucket" ]]; then
    continue
  fi
  if [[ ! "$bucket_name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    continue
  fi

  size_val=$(echo "$line" | grep -oP 'size:\K[0-9]+' || echo 0)
  logical_val=$(echo "$line" | grep -oP 'logical:\K[0-9]+' || echo 0)
  chunk_val=$(echo "$line" | grep -oP 'chunk:\K[0-9]+' || echo 0)
  quota_val=$(echo "$line" | grep -oP 'quota:\K[0-9]+' || echo 0)
  usage_val=$(echo "$line" | grep -oP 'usage:\K[0-9.]+' || echo 0)

  bucket_names+=("$bucket_name")
  bucket_sizes+=("$size_val")
  bucket_logicals+=("$logical_val")
  bucket_chunks+=("$chunk_val")
  bucket_quotas+=("$quota_val")
  bucket_usages+=("$usage_val")
done <<< "$bucket_output"

if [[ ${#bucket_names[@]} -eq 0 ]]; then
  swf_add_issue \
    "SeaweedFS bucket list returned no parseable buckets from \`${master_pod}\`" \
    "weed shell s3.bucket.list output was received but no bucket entries could be parsed. Output may have changed format.\n\nRaw output (first 1000 chars):\n${bucket_output:0:1000}" \
    3 \
    "Verify manually: kubectl exec ${master_pod} -n ${NAMESPACE} -- weed shell -master=localhost:9333 -c 's3.bucket.list'"
  swf_write_issues "$OUTPUT_FILE"
  exit 0
fi

# Compute totals
total_logical=0
total_physical=0
total_objects=0
warn_count=0
crit_count=0
declare -a warn_buckets crit_buckets

for i in "${!bucket_names[@]}"; do
  total_logical=$((total_logical + ${bucket_logicals[$i]}))
  total_physical=$((total_physical + ${bucket_sizes[$i]}))
  total_objects=$((total_objects + ${bucket_chunks[$i]}))
  usage="${bucket_usages[$i]}"
  if [[ "$(awk "BEGIN {print ($usage >= $QUOTA_CRIT_PCT) ? 1 : 0}")" == "1" ]]; then
    crit_count=$((crit_count + 1))
    crit_buckets+=("$i")
  elif [[ "$(awk "BEGIN {print ($usage >= $QUOTA_WARN_PCT) ? 1 : 0}")" == "1" ]]; then
    warn_count=$((warn_count + 1))
    warn_buckets+=("$i")
  fi
done

echo "Buckets: ${#bucket_names[@]} | Total logical: $(fmt_size $total_logical) | Total physical: $(fmt_size $total_physical) | Objects: ${total_objects}"
echo ""
printf "%-30s %10s %10s %8s %10s %7s\n" "Bucket" "Logical" "Physical" "Objects" "Quota" "Usage"
printf "%s\n" "$(printf '%.0s-' {1..85})"

# Sort by logical size descending and print
declare -a sorted_indices
sorted_indices=($(for i in "${!bucket_logicals[@]}"; do echo "$i ${bucket_logicals[$i]}"; done | sort -k2 -rn | head -n "$MAX_BUCKETS_SHOWN" | awk '{print $1}'))

for idx in "${sorted_indices[@]}"; do
  name="${bucket_names[$idx]}"
  logical_s=$(fmt_size "${bucket_logicals[$idx]}")
  physical_s=$(fmt_size "${bucket_sizes[$idx]}")
  objects="${bucket_chunks[$idx]}"
  quota="${bucket_quotas[$idx]}"
  quota_s=$([ "$quota" -gt 0 ] && fmt_size "$quota" || echo "—")
  usage="${bucket_usages[$idx]}"
  usage_s=$(awk "BEGIN {if ($usage > 0) printf \"%.1f%%\", $usage; else print \"—\"}")
  flag=""
  if [[ "$(awk "BEGIN {print ($usage >= $QUOTA_CRIT_PCT) ? 1 : 0}")" == "1" ]]; then
    flag=" CRIT"
  elif [[ "$(awk "BEGIN {print ($usage >= $QUOTA_WARN_PCT) ? 1 : 0}")" == "1" ]]; then
    flag=" WARN"
  fi
  printf "%-30s %10s %10s %8s %10s %7s%s\n" "$name" "$logical_s" "$physical_s" "$objects" "$quota_s" "$usage_s" "$flag"
done

echo ""
echo "Summary: ${#bucket_names[@]} buckets | ${warn_count} warn (>${QUOTA_WARN_PCT}%) | ${crit_count} critical (>${QUOTA_CRIT_PCT}%)"

for idx in "${crit_buckets[@]}"; do
  name="${bucket_names[$idx]}"
  usage="${bucket_usages[$idx]}"
  logical_s=$(fmt_size "${bucket_logicals[$idx]}")
  physical_s=$(fmt_size "${bucket_sizes[$idx]}")
  quota_s=$(fmt_size "${bucket_quotas[$idx]}")
  quota_raw="${bucket_quotas[$idx]}"
  swf_add_issue \
    "CRITICAL: Bucket \`${name}\` at ${usage}% of quota (${logical_s} / ${quota_s})" \
    "Bucket \`${name}\` in namespace ${NAMESPACE} has exceeded the critical threshold of ${QUOTA_CRIT_PCT}%.\n\nLogical size: ${logical_s}\nPhysical size: ${physical_s}\nObject count: ${bucket_chunks[$idx]}\nQuota: ${quota_s}\nUsage: ${usage}%" \
    1 \
    "1. Investigate data growth in bucket '${name}' — check for runaway uploads or missing TTL/retention policies.\n2. Increase the bucket quota via s3.bucket.quota: weed shell -master=<master>:9333 -c \"s3.bucket.quota -name ${name} -size <new_quota_gb>GB\"\n3. Review compaction and garbage collection cadence."
done

for idx in "${warn_buckets[@]}"; do
  name="${bucket_names[$idx]}"
  usage="${bucket_usages[$idx]}"
  logical_s=$(fmt_size "${bucket_logicals[$idx]}")
  physical_s=$(fmt_size "${bucket_sizes[$idx]}")
  quota_s=$(fmt_size "${bucket_quotas[$idx]}")
  swf_add_issue \
    "WARNING: Bucket \`${name}\` at ${usage}% of quota (${logical_s} / ${quota_s})" \
    "Bucket \`${name}\` in namespace ${NAMESPACE} is approaching its quota at ${usage}%.\n\nLogical size: ${logical_s}\nPhysical size: ${physical_s}\nObject count: ${bucket_chunks[$idx]}\nQuota: ${quota_s}\nUsage: ${usage}%" \
    3 \
    "Monitor growth trend for bucket '${name}'. If growth continues, increase quota or implement cleanup policy before the bucket reaches critical capacity."
done

# Summary issue
if [[ "$crit_count" -eq 0 && "$warn_count" -eq 0 ]]; then
  summary_severity=4
  summary_title="SeaweedFS Bucket Usage: ${#bucket_names[@]} buckets healthy ($(fmt_size $total_logical) logical)"
else
  if [[ "$crit_count" -gt 0 ]]; then
    summary_severity=1
  else
    summary_severity=3
  fi
  summary_title="SeaweedFS Bucket Usage: ${crit_count} critical, ${warn_count} warning out of ${#bucket_names[@]} buckets ($(fmt_size $total_logical) logical)"
fi

swf_add_issue \
  "$summary_title" \
  "Per-bucket SeaweedFS storage consumption in ${NAMESPACE}.\n\n- Buckets total: ${#bucket_names[@]}\n- Total logical size: $(fmt_size $total_logical)\n- Total physical size: $(fmt_size $total_physical)\n- Total objects: ${total_objects}\n- Warning threshold: ${QUOTA_WARN_PCT}%\n- Critical threshold: ${QUOTA_CRIT_PCT}%\n- Buckets above warning: ${warn_count}\n- Buckets above critical: ${crit_count}\n\nFull report printed to stdout." \
  "$summary_severity" \
  "Review stdout for per-bucket detail. Address critical buckets immediately by increasing quota or implementing data lifecycle policies."

swf_write_issues "$OUTPUT_FILE"