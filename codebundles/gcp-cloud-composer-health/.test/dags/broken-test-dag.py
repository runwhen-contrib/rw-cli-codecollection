# -----------------------------------------------------------------------------
# Deliberately broken DAG used to exercise gcp-cloud-composer-health detections.
#
# This DAG parses cleanly (so it appears in `dags list-runs`) but its single
# task always raises. Triggering it produces:
#   - a failed DAG run            (check_jobs_and_scheduler.sh)
#   - a failing task instance     (check_jobs_and_scheduler.sh)
#   - ERROR entries in Cloud Logging (get_error_logs.sh)
# -----------------------------------------------------------------------------
from datetime import datetime

from airflow import DAG
from airflow.operators.python import PythonOperator


def intentionally_broken(**context):
    raise RuntimeError("Intentional test failure: this task always fails")


with DAG(
    dag_id="broken-test-dag",
    schedule=None,
    start_date=datetime(2024, 1, 1),
    catchup=False,
    tags=["test", "broken", "runwhen"],
) as dag:
    always_failing_task = PythonOperator(
        task_id="always_failing_task",
        python_callable=intentionally_broken,
    )
