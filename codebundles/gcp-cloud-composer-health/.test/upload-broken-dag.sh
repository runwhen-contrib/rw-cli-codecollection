#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Uploads and triggers the broken DAG against a (shared) Cloud Composer
# environment so the gcp-cloud-composer-health detections have something to
# find: failed DAG runs, failing task instances, and error logs.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#   ENV_NAME        - target environment (default balanced-composer-test001)
#   LOCATION        - environment region (default us-central1)
#   GOOGLE_APPLICATION_CREDENTIALS
#
# The DAG source lives next to this script in ./dags/.
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
ENV_NAME="${ENV_NAME:-balanced-composer-test001}"
LOCATION="${LOCATION:-us-central1}"
DAG_ID="broken-test-dag"
DAGS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/dags" && pwd)"

echo "Uploading broken DAG to environment '${ENV_NAME}' (${LOCATION})..."
gcloud composer environments storage dags import \
    --environment="${ENV_NAME}" \
    --location="${LOCATION}" \
    --project="${GCP_PROJECT_ID}" \
    --source="${DAGS_DIR}"

echo "Waiting for Airflow to parse the DAG..."
for i in $(seq 1 20); do
    if gcloud composer environments run "${ENV_NAME}" \
        --location="${LOCATION}" \
        --project="${GCP_PROJECT_ID}" \
        dags list -o json 2>/dev/null | jq -e '.[] | select(.dag_id == "'"${DAG_ID}"'")' >/dev/null 2>&1; then
        echo "DAG '${DAG_ID}' is visible to Airflow."
        break
    fi
    echo "  ... DAG not yet parsed (attempt ${i}/20)"
    sleep 15
done

echo "Triggering DAG run for '${DAG_ID}'..."
run_id="broken-test-run-$(date +%s)"
gcloud composer environments run "${ENV_NAME}" \
    --location="${LOCATION}" \
    --project="${GCP_PROJECT_ID}" \
    dags trigger -- "${DAG_ID}" --run_id="${run_id}"

echo "Triggered '${DAG_ID}' with run_id '${run_id}'."
echo "The task will fail shortly; re-run the gcp-cloud-composer-health runbook to observe:"
echo "  - Failed DAG runs"
echo "  - Failing task instances"
echo "  - ERROR log entries"
