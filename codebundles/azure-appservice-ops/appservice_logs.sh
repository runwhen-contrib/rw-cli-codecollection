#!/usr/bin/env bash
#
# appservice_logs.sh
#
# Fetches logs from an Azure App Service, unzips them, and displays key sections (Application logs, DetailedErrors, eventlog.xml)
# in a simplified form. If 'xmllint' is installed, eventlog.xml is parsed for each <Event> node to provide a cleaner summary.

set -euo pipefail

##############################################################################
# 1) Environment & Arguments
##############################################################################
if [[ -z "${AZ_RESOURCE_GROUP:-}" ]]; then
  echo "Error: AZ_RESOURCE_GROUP is not set."
  exit 1
fi

if [[ -z "${APP_SERVICE_NAME:-}" ]]; then
  echo "Error: APP_SERVICE_NAME is not set."
  exit 1
fi

OUTPUT_DIR="${OUTPUT_DIR:-./output}"
mkdir -p "${OUTPUT_DIR}"

TIMESTAMP="$(date +%Y%m%d%H%M%S)"
LOG_FILE="${OUTPUT_DIR}/${APP_SERVICE_NAME}_logs_${TIMESTAMP}.zip"
UNZIP_DIR="${OUTPUT_DIR}/${APP_SERVICE_NAME}_logs_${TIMESTAMP}"

##############################################################################
# 2) Download Logs
##############################################################################
echo "Downloading logs for App Service '${APP_SERVICE_NAME}' in resource group '${AZ_RESOURCE_GROUP}'..."
az webapp log download \
  --resource-group "${AZ_RESOURCE_GROUP}" \
  --name "${APP_SERVICE_NAME}" \
  --log-file "${LOG_FILE}" \
  2>&1

if [[ ! -f "${LOG_FILE}" ]]; then
  echo "Error: No log file was downloaded to ${LOG_FILE}. Please check the Azure CLI output above."
  exit 1
fi

echo "Logs successfully downloaded: ${LOG_FILE}"

##############################################################################
# 3) Unzip Logs
##############################################################################
mkdir -p "${UNZIP_DIR}"
unzip -o "${LOG_FILE}" -d "${UNZIP_DIR}" && echo "Logs unzipped to: ${UNZIP_DIR}"
echo ""

# If you no longer need the ZIP archive, you could optionally remove it:
# rm -f "${LOG_FILE}"

##############################################################################
# 4) Display Key Log Sections
##############################################################################
echo "=== Listing All Downloaded Log Files ==="
find "${UNZIP_DIR}" -type f
echo ""

# --- A) Application Logs (most common place to see console output, exceptions, etc.)
APP_LOG_DIR="${UNZIP_DIR}/LogFiles/Application"
if [[ -d "${APP_LOG_DIR}" ]]; then
  echo "=== Application Logs ==="
  for f in "${APP_LOG_DIR}"/*; do
    if [[ -f "$f" ]]; then
      echo "---------- $f ----------"
      # For large logs, consider tail/head or grep. For example:
      # tail -n 200 "$f"
      cat "$f"
      echo ""
    fi
  done
else
  echo "No Application logs found at ${APP_LOG_DIR}"
fi
echo ""

# --- B) Detailed Errors (HTTP 4xx/5xx). Often has subdirectories named after the error code.
DETAIL_DIR="${UNZIP_DIR}/LogFiles/DetailedErrors"
if [[ -d "${DETAIL_DIR}" ]]; then
  echo "=== Detailed Error Logs (4xx / 5xx) ==="
  for err_file in "${DETAIL_DIR}"/*; do
    if [[ -f "$err_file" ]]; then
      echo "---------- $err_file ----------"
      cat "$err_file"
      echo ""
    fi
  done
fi
echo ""

# --- C) eventlog.xml (Windows-based App Service). Attempt to parse or at least show partial content.
EVENTLOG_FILE="${UNZIP_DIR}/LogFiles/eventlog.xml"
if [[ -f "${EVENTLOG_FILE}" ]]; then
  echo "=== System Event Log (Simplified) ==="
  if command -v xmllint &>/dev/null; then
    # Using xmllint to extract a simpler summary from each <Event> node
    # This XPath expression tries to print key fields: timestamp, event ID, level, message
    # You can customize it to show more or less detail.
    xmllint --xpath '
      //Event/concat(
        "Time=", System/TimeCreated/@SystemTime,
        " | EventID=", System/EventID/text(),
        " | Level=", System/Level/text(),
        " | Message=", RenderingInfo/Message/text(),
        "\n"
      )
    ' "${EVENTLOG_FILE}" 2>/dev/null || true
  else
    echo "xmllint not installed, showing raw eventlog.xml content below..."
    cat "${EVENTLOG_FILE}"
  fi
fi

# Done
