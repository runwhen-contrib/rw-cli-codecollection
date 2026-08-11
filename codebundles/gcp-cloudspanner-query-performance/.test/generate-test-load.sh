#!/usr/bin/env bash
set -uo pipefail
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#   HEALTHY_INSTANCE_ID
#   HEALTHY_DATABASE_ID
#   CONTENDED_INSTANCE_ID
#   CONTENDED_DATABASE_ID
#
# This script drives real query traffic against the two Terraform-provisioned
# test databases so SPANNER_SYS.QUERY_STATS_TOP_*, LOCK_STATS_TOP_*, and
# TXN_STATS_TOP_* are actually populated -- those tables are empty for a
# database that has had no traffic, regardless of how it is configured.
#
#   healthy_workload:   a handful of fast, uncontended single-row SELECTs.
#                        Expected to stay under every threshold.
#   contended_workload:  many concurrent single-row UPDATE statements against
#                        the SAME row, executed via gcloud in parallel
#                        background processes. Spanner serializes writers to
#                        a row under pessimistic locking, so this reliably
#                        produces LOCK_STATS lock-wait time and a share of
#                        TXN_STATS commit aborts (Spanner aborts a transaction
#                        rather than let it wait indefinitely under
#                        contention/deadlock-avoidance).
#
# Run this AFTER `task build-infra` and BEFORE running the runbook/SLI so the
# STATS_WINDOW (MINUTE/10MINUTE/HOUR) you test against actually contains this
# traffic. Query stats tables trail live traffic by roughly a minute, so wait
# ~60-90s after this script completes before running the CodeBundle against
# the MINUTE window (the default HOUR window has more headroom).
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${HEALTHY_INSTANCE_ID:?Must set HEALTHY_INSTANCE_ID}"
: "${HEALTHY_DATABASE_ID:?Must set HEALTHY_DATABASE_ID}"
: "${CONTENDED_INSTANCE_ID:?Must set CONTENDED_INSTANCE_ID}"
: "${CONTENDED_DATABASE_ID:?Must set CONTENDED_DATABASE_ID}"

echo "=== healthy_workload: generating light, uncontended read traffic ==="
gcloud spanner databases execute-sql "$HEALTHY_DATABASE_ID" \
  --instance="$HEALTHY_INSTANCE_ID" --project="$GCP_PROJECT_ID" \
  --sql="INSERT INTO Items (ItemId, ItemName, CreatedAt) VALUES (1, 'seed-item', PENDING_COMMIT_TIMESTAMP())" \
  >/dev/null 2>&1 || echo "(seed row may already exist, continuing)"

for i in $(seq 1 10); do
  gcloud spanner databases execute-sql "$HEALTHY_DATABASE_ID" \
    --instance="$HEALTHY_INSTANCE_ID" --project="$GCP_PROJECT_ID" \
    --sql="SELECT ItemId, ItemName FROM Items LIMIT 10" >/dev/null 2>&1
done
echo "healthy_workload: issued 10 fast SELECT statements."

echo "=== contended_workload: seeding Counters row ==="
existing=$(gcloud spanner databases execute-sql "$CONTENDED_DATABASE_ID" \
  --instance="$CONTENDED_INSTANCE_ID" --project="$GCP_PROJECT_ID" \
  --sql="SELECT COUNT(*) FROM Counters WHERE Id = 1" --format="value(f_0)" 2>/dev/null || echo "0")
if [ "$existing" = "0" ] || [ -z "$existing" ]; then
  gcloud spanner databases execute-sql "$CONTENDED_DATABASE_ID" \
    --instance="$CONTENDED_INSTANCE_ID" --project="$GCP_PROJECT_ID" \
    --sql="INSERT INTO Counters (Id, Value) VALUES (1, 0)" >/dev/null 2>&1 || true
fi

echo "=== contended_workload: firing concurrent UPDATEs at the same row ==="
pids=()
for i in $(seq 1 25); do
  (
    gcloud spanner databases execute-sql "$CONTENDED_DATABASE_ID" \
      --instance="$CONTENDED_INSTANCE_ID" --project="$GCP_PROJECT_ID" \
      --sql="UPDATE Counters SET Value = Value + 1 WHERE Id = 1" \
      >/dev/null 2>&1
  ) &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  wait "$pid" || true
done
echo "contended_workload: issued 25 concurrent UPDATE statements against the same row."

echo "Load generation complete. Allow ~60-90s for SPANNER_SYS to reflect this traffic before scoring the MINUTE/10MINUTE window (the HOUR window has more headroom)."
