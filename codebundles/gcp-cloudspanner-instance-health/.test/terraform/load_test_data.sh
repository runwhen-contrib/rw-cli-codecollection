#!/usr/bin/env bash
set -euo pipefail
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   PROJECT_ID    - GCP project containing the instance
#   INSTANCE_ID   - Spanner instance name
#   DATABASE_ID   - Spanner database name
#
# OPTIONAL ENV VARS:
#   ROW_COUNT     - Number of rows to insert (default: 64)
#   PAYLOAD_BYTES - Size of the Payload string per row in bytes (default: 65536)
#   TABLE         - Table to insert into (default: Events)
#
# Inserts ROW_COUNT rows with a PAYLOAD_BYTES-sized Payload column so that
# DATABASE_ID carries a few MB of data. Used by the terraform null_resource
# "load_overloaded_data" to give the overloaded_instance scenario real stored
# bytes, so STORAGE_UTILIZATION_THRESHOLD can be exercised cheaply by setting
# the threshold/limit env vars low (e.g. STORAGE_UTILIZATION_THRESHOLD=0).
#
# Payload is hex-encoded so it contains no characters that would break the
# gcloud --data=COL=VAL parser (commas, equals signs).
# -----------------------------------------------------------------------------

: "${PROJECT_ID:?Must set PROJECT_ID}"
: "${INSTANCE_ID:?Must set INSTANCE_ID}"
: "${DATABASE_ID:?Must set DATABASE_ID}"

ROW_COUNT="${ROW_COUNT:-64}"
PAYLOAD_BYTES="${PAYLOAD_BYTES:-65536}"
TABLE="${TABLE:-Events}"

payload=$(head -c $((PAYLOAD_BYTES / 2)) /dev/urandom | od -An -tx1 | tr -d ' \n')

echo "Loading $ROW_COUNT rows x $PAYLOAD_BYTES bytes into $TABLE ($PROJECT_ID/$INSTANCE_ID/$DATABASE_ID)..."

for i in $(seq 1 "$ROW_COUNT"); do
  gcloud spanner rows insert \
    --project="$PROJECT_ID" \
    --instance="$INSTANCE_ID" \
    --database="$DATABASE_ID" \
    --table="$TABLE" \
    --data="EventId=$i,Payload=$payload,CreatedAt=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >/dev/null
done

echo "Done. Inserted $ROW_COUNT row(s), ~$((ROW_COUNT * PAYLOAD_BYTES / 1024 / 1024)) MB total."
