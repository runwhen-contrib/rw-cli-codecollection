#!/usr/bin/env bash
set -euo pipefail
set -x
# Performs minimal S3 ListBuckets and put/get/delete of a temporary object.
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

OUTPUT_FILE="s3_gateway_issues.json"
PROBE_PREFIX="runwhen-seaweedfs-probe"
# shellcheck disable=SC1091
source seaweedfs-lib.sh

print_report() {
  { set +x; } 2>/dev/null || true
  echo "=== SeaweedFS S3 gateway probe ==="
  jq -r '.[] | "  - [sev=\(.severity)] \(.title)"' "$OUTPUT_FILE" 2>/dev/null || true
}
trap print_report EXIT

filer_pod=$(swf_find_pod "filer")
if [[ -z "$filer_pod" ]]; then
  swf_add_issue \
    "S3 gateway probe skipped: no filer pod in namespace \`${NAMESPACE}\`" \
    "S3 is served from the filer component in default Helm installs." \
    3 \
    "Enable filer and S3 in Helm values (filer.s3.enabled)."
  swf_write_issues "$OUTPUT_FILE"
  exit 0
fi

# Detect if S3 port responds locally
if ! swf_pod_http "$filer_pod" "$S3_PORT" "/" >/dev/null 2>&1; then
  swf_add_issue \
    "SeaweedFS S3 endpoint not listening on filer port ${S3_PORT} in \`${NAMESPACE}\`" \
    "S3 may be disabled in Helm values; probe skipped without raising critical failure." \
    3 \
    "Set filer.s3.enabled=true and expose port ${S3_PORT} if S3 is required."
  swf_write_issues "$OUTPUT_FILE"
  exit 0
fi

swf_parse_s3_credentials

bucket="${S3_PROBE_BUCKET:-runwhen-healthcheck}"
object_key="${PROBE_PREFIX}/$(date +%s)-$$.txt"
tmp_body="/tmp/seaweedfs_probe_$$.txt"
echo "runwhen seaweedfs probe $(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$tmp_body"

run_in_filer() {
  local cmd="$1"
  "${KUBECTL}" exec -n "${NAMESPACE}" --context "${CONTEXT}" "$filer_pod" -- sh -c "$cmd"
}

aws_env=""
if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
  aws_env="AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}"
fi

endpoint="http://127.0.0.1:${S3_PORT}"

# List buckets
if ! list_out=$(run_in_filer "${aws_env} AWS_EC2_METADATA_DISABLED=true aws --endpoint-url ${endpoint} s3 ls 2>&1" 2>/dev/null); then
  if echo "$list_out" | grep -qiE 'Unable to locate credentials|AccessDenied|403|401'; then
    swf_add_issue \
      "SeaweedFS S3 ListBuckets failed (auth) in namespace \`${NAMESPACE}\`" \
      "$list_out" \
      2 \
      "Provide seaweedfs_s3_credentials secret or configure anonymous access for probe bucket."
    swf_write_issues "$OUTPUT_FILE"
    rm -f "$tmp_body"
    exit 0
  fi
  if ! echo "$list_out" | grep -qi 'aws: not found'; then
    swf_add_issue \
      "SeaweedFS S3 ListBuckets failed in namespace \`${NAMESPACE}\`" \
      "$list_out" \
      2 \
      "Verify filer S3 configuration and IAM user mappings."
    swf_write_issues "$OUTPUT_FILE"
    rm -f "$tmp_body"
    exit 0
  fi
fi

# Create bucket if missing (best effort)
if [[ -z "${S3_PROBE_BUCKET:-}" ]]; then
  run_in_filer "${aws_env} AWS_EC2_METADATA_DISABLED=true aws --endpoint-url ${endpoint} s3 mb s3://${bucket} 2>/dev/null" || true
fi

put_cmd="cat > ${tmp_body} && ${aws_env} AWS_EC2_METADATA_DISABLED=true aws --endpoint-url ${endpoint} s3 cp ${tmp_body} s3://${bucket}/${object_key}"
get_cmd="${aws_env} AWS_EC2_METADATA_DISABLED=true aws --endpoint-url ${endpoint} s3 cp s3://${bucket}/${object_key} -"
del_cmd="${aws_env} AWS_EC2_METADATA_DISABLED=true aws --endpoint-url ${endpoint} s3 rm s3://${bucket}/${object_key}"

if ! run_in_filer "$put_cmd" >/dev/null 2>&1; then
  swf_add_issue \
    "SeaweedFS S3 put object failed in namespace \`${NAMESPACE}\`" \
    "Could not upload s3://${bucket}/${object_key}" \
    2 \
    "Check filer S3 auth, bucket policy, and filer-to-volume connectivity."
  swf_write_issues "$OUTPUT_FILE"
  rm -f "$tmp_body"
  exit 0
fi

if ! got=$(run_in_filer "$get_cmd" 2>/dev/null); then
  swf_add_issue \
    "SeaweedFS S3 get object failed in namespace \`${NAMESPACE}\`" \
    "Uploaded object s3://${bucket}/${object_key} could not be read back." \
    2 \
    "Inspect filer and volume logs for write/read errors."
  run_in_filer "$del_cmd" >/dev/null 2>&1 || true
  swf_write_issues "$OUTPUT_FILE"
  rm -f "$tmp_body"
  exit 0
fi

if ! echo "$got" | grep -q 'runwhen seaweedfs probe'; then
  swf_add_issue \
    "SeaweedFS S3 object content mismatch in namespace \`${NAMESPACE}\`" \
    "Read payload did not match uploaded probe object." \
    2 \
    "Investigate filer metadata store and erasure coding health."
fi

run_in_filer "$del_cmd" >/dev/null 2>&1 || true
rm -f "$tmp_body"

swf_write_issues "$OUTPUT_FILE"
