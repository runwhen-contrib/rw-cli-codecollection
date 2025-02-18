#!/usr/bin/env bash
#
# appservice_restart_with_logs.sh
#
# This script:
#   1. Fetches logs and shows the last 50 lines (Pre-Restart).
#   2. Restarts the App Service.
#   3. Verifies the restart via Azure Activity Log.
#   4. Fetches logs again and shows the last 50 lines (Post-Restart).
#   5. Prints a single Azure Portal link at the end.
#
# Required ENV vars:
#   AZ_RESOURCE_GROUP - The resource group of your App Service.
#   APP_SERVICE_NAME  - The name of your App Service.
#
# Optional ENV vars:
#   OUTPUT_DIR        - Where logs (ZIP/unzipped) will be stored (default: ./output).
#   RESTART_LOOKBACK  - How many minutes to look back in the Activity Log (default: 15).
#   TAIL_LINES        - How many lines of each log file to display (default: 50).
#   AZ_SUBSCRIPTION_ID - (Optional) subscription ID to build a direct portal link.
#
# Usage:
#   export AZ_RESOURCE_GROUP=myRG
#   export APP_SERVICE_NAME=myAppSvc
#   export AZ_SUBSCRIPTION_ID=<your subscription>
#   bash appservice_restart_with_logs.sh

# set -euo pipefail  # Uncomment to enable strict error handling

##############################################################################
# 0) Environment & Defaults
##############################################################################
: "${AZ_RESOURCE_GROUP:?Need to set AZ_RESOURCE_GROUP}"
: "${APP_SERVICE_NAME:?Need to set APP_SERVICE_NAME}"

OUTPUT_DIR="${OUTPUT_DIR:-./output}"
RESTART_LOOKBACK="${RESTART_LOOKBACK:-15}"   # minutes
TAIL_LINES="${TAIL_LINES:-50}"
AZ_SUBSCRIPTION_ID="${AZ_SUBSCRIPTION_ID:-}"

mkdir -p "${OUTPUT_DIR}"

##############################################################################
# 1) Function: Download logs & tail last N lines
##############################################################################
function fetch_and_tail_logs() {
  local label="$1"  # "Pre-Restart" or "Post-Restart" etc.

  echo "===== [${label}] Downloading logs for App Service '${APP_SERVICE_NAME}' ====="
  local timestamp
  timestamp="$(date +%Y%m%d%H%M%S)"
  local zip_file="${OUTPUT_DIR}/${APP_SERVICE_NAME}_logs_${label}_${timestamp}.zip"
  local unzip_dir="${OUTPUT_DIR}/${APP_SERVICE_NAME}_logs_${label}_${timestamp}"

  # Download logs
  az webapp log download \
    --resource-group "${AZ_RESOURCE_GROUP}" \
    --name "${APP_SERVICE_NAME}" \
    --log-file "${zip_file}" \
    2>&1

  # Unzip
  mkdir -p "${unzip_dir}"
  if [[ -f "${zip_file}" ]]; then
    unzip -o "${zip_file}" -d "${unzip_dir}" >/dev/null 2>&1 || true
  fi

  echo "Logs saved and extracted to: ${unzip_dir}"
  echo ""

  # Tail the last N lines of each Application log
  local app_log_dir="${unzip_dir}/LogFiles/Application"
  if [[ -d "${app_log_dir}" ]]; then
    echo "===== [${label}] Showing the last ${TAIL_LINES} lines from Application logs ====="
    shopt -s nullglob
    for logfile in "${app_log_dir}"/*; do
      if [[ -f "${logfile}" ]]; then
        echo "---------- ${logfile} ----------"
        tail -n "${TAIL_LINES}" "${logfile}"
        echo ""
      fi
    done
    shopt -u nullglob
  else
    echo "[${label}] No Application logs found in ${app_log_dir}"
  fi

  # Optional: Stream logs for a short period (15s), merging stderr into stdout
  timeout 15 az webapp log tail \
    --name "${APP_SERVICE_NAME}" \
    --resource-group "${AZ_RESOURCE_GROUP}" \
    2>&1

  echo "===== End [${label}] Logs ====="
  echo ""
}

##############################################################################
# 2) Function: Verify the restart in the Azure Activity Log
##############################################################################
function verify_restart_in_activity_log() {
  echo "===== Checking Azure Activity Log for a 'restart' event in last ${RESTART_LOOKBACK} minutes ====="

  # We'll look back N minutes. Adjust as needed or use an absolute time range.
  local start_time
  start_time="$(date -u -d "-${RESTART_LOOKBACK} minutes" +"%Y-%m-%dT%H:%M:%SZ")"

  # Look for either 'RestartWebSite' or 'Microsoft.Web/sites/restart/action'
  local activity_log
  activity_log="$(
    az monitor activity-log list \
      --resource-group "${AZ_RESOURCE_GROUP}" \
      --start-time "${start_time}" \
      --query "[?(operationName.value=='RestartWebSite' || operationName.value=='Microsoft.Web/sites/restart/action') && contains(resourceId, '${APP_SERVICE_NAME}')]" \
      --output json 2>/dev/null || true
  )"

  # Count how many events matched
  local count
  count="$(echo "${activity_log}" | python -c 'import json,sys; data=json.load(sys.stdin); print(len(data))' 2>/dev/null || echo 0 )"

  if [[ "${count}" -gt 0 ]]; then
    echo "Found ${count} 'restart' event(s) in the last ${RESTART_LOOKBACK} minutes for '${APP_SERVICE_NAME}'."
    date=$(date -u)
    echo "Current time (UTC): $date"

    # Summarize in a table (timestamp, operationName, status, caller)
    echo "${activity_log}" | python -c '
import sys, json

data = json.load(sys.stdin)
if not isinstance(data, list):
    data = [data]

print("\nActivity Log Restart Summary (table format)")
print("-------------------------------------------------------------------------------------")
print("Timestamp (UTC)         | OperationName                      | Status       | Caller")
print("------------------------|------------------------------------|--------------|----------------------")

for e in data:
    ts = e.get("eventTimestamp", "")
    op = e.get("operationName", {}).get("value", "")
    st = e.get("status", {}).get("value", "")
    cl = e.get("caller", "")
    print(f"{ts:<24} | {op:<34} | {st:<12} | {cl}")

print("-------------------------------------------------------------------------------------\n")
'

  else
    echo "No 'restart' events found in the Azure Activity Log for the last ${RESTART_LOOKBACK} minutes."
    echo "Check your time window or confirm the restart command actually executed."
  fi
  echo ""
}

##############################################################################
# 3) Main Execution Steps
##############################################################################

# A) Fetch Pre-Restart Logs
fetch_and_tail_logs "Pre-Restart"

# B) Restart the App Service
echo "===== Restarting App Service '${APP_SERVICE_NAME}' ====="
if ! az webapp restart --name "${APP_SERVICE_NAME}" --resource-group "${AZ_RESOURCE_GROUP}"; then
  echo "ERROR: Failed to restart App Service."
  exit 1
fi
echo "App Service restart command completed."
echo ""

# (Optional) Wait a few seconds to allow the Activity Log to register the event
sleep 10

# C) Verify the restart happened via Activity Log
verify_restart_in_activity_log

# D) Fetch Post-Restart Logs
fetch_and_tail_logs "Post-Restart"

echo "===== Script Complete ====="
echo ""

##############################################################################
# 4) Print a Single Portal Link at the End
##############################################################################
if [[ -n "${AZ_SUBSCRIPTION_ID}" ]]; then
  echo "To view your App Service in the Azure Portal, open the link below:"
  echo "https://portal.azure.com/#resource/subscriptions/${AZ_SUBSCRIPTION_ID}/resourceGroups/${AZ_RESOURCE_GROUP}/providers/Microsoft.Web/sites/${APP_SERVICE_NAME}/overview"
  echo ""
else
  echo "If you want a direct Azure Portal link, set AZ_SUBSCRIPTION_ID in your environment."
  echo "e.g.:  export AZ_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000000"
  echo "Then run this script again."
fi
