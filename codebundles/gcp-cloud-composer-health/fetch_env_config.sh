#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID  - GCP project containing Cloud Composer environments
#   ENV_NAME        - optional; pin to a single environment name, or 'All'
#
# Dumps the full environment configuration (airflow/image version, software
# config, scheduler/worker/node counts, web server, networking) for every
# environment and flags missing, misconfigured, or outdated settings (e.g.
# environments on outdated or non-LTS airflow/composer image versions).
# Outputs a JSON array of issues to env_config_issues.json.
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${ENV_NAME:=All}"

OUTPUT_FILE="env_config_issues.json"
REPORT_FILE="env_config_report.json"
TMP_FILE="${OUTPUT_FILE}.tmp"
> "$TMP_FILE"
> "$REPORT_FILE"

echo "Fetching Cloud Composer environment configurations for project: $GCP_PROJECT_ID"

envs=$(gcloud composer environments list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")

if [ "$(echo "$envs" | jq 'length')" -eq 0 ]; then
  echo "No Cloud Composer environments found in project $GCP_PROJECT_ID."
  echo "[]" > "$OUTPUT_FILE"
  echo "[]" > "$REPORT_FILE"
  rm -f "$TMP_FILE"
  exit 0
fi

echo "$envs" | jq -c '.[]' | while read -r env; do
  name=$(echo "$env" | jq -r '.name')
  short_name=$(echo "$name" | awk -F'/' '{print $NF}')
  location=$(echo "$env" | jq -r '.location')

  if [ "$ENV_NAME" != "All" ] && [ "$ENV_NAME" != "$short_name" ]; then
    continue
  fi

  echo "Describing environment: $short_name (location: $location)"
  desc=$(gcloud composer environments describe "$short_name" \
    --location="$location" \
    --project="$GCP_PROJECT_ID" \
    --format=json 2>/dev/null || echo "{}")

  echo "$desc" | jq -c --arg n "$short_name" --arg l "$location" \
    '. + {shortName: $n, location: $l}' >> "$REPORT_FILE"

  image_version=$(echo "$desc" | jq -r '.config.softwareConfig.imageVersion // empty')
  airflow_version=""
  if [ -n "$image_version" ]; then
    airflow_version=$(echo "$image_version" | sed -E 's/.*airflow-([0-9]+\.[0-9]+).*/\1/')
  fi

  node_count=$(echo "$desc" | jq -r '.config.nodeCount // "not set"')
  scheduler_count=$(echo "$desc" | jq -r '.config.workloadsConfig.scheduler.count // "not set"')
  worker_count=$(echo "$desc" | jq -r '.config.workloadsConfig.worker.count // "not set"')
  web_server_count=$(echo "$desc" | jq -r '.config.workloadsConfig.webServer.count // "not set"')
  env_size=$(echo "$desc" | jq -r '.config.environmentSize // "not set"')
  airflow_uri=$(echo "$desc" | jq -r '.config.airflowUri // (.airflowUris[0] // empty)')

  echo "  image=$image_version env_size=$env_size nodes=$node_count scheduler=$scheduler_count worker=$worker_count web=$web_server_count"

  # Flag outdated or non-LTS airflow/composer image versions.
  if [ -n "$image_version" ]; then
    comet_version=$(echo "$image_version" | sed -E 's/^(composer-[0-9]+).*/\1/')
    if [ "$comet_version" = "composer-1" ]; then
      printf '{"title":"Cloud Composer environment `%s` uses a deprecated composer-1 image","expected":"Cloud Composer environment `%s` should run a supported Composer 2 image on an LTS Airflow version","actual":"Cloud Composer environment `%s` runs image `%s`, which is a deprecated composer-1 image","severity":3,"details":"Environment `%s` in location `%s` of project `%s` uses image `%s`. Composer 1 images are deprecated and do not receive security updates.","next_steps":"Upgrade the environment to a supported Composer 2 image. Plan a DAG compatibility review and schedule a controlled upgrade using `gcloud composer environments update` with the `--image-version` flag.","environment":"%s","image_version":"%s","issue_type":"composer_image_deprecated"}\n' \
        "$short_name" "$short_name" "$short_name" "$image_version" \
        "$short_name" "$location" "$GCP_PROJECT_ID" "$image_version" "$short_name" "$image_version" >> "$TMP_FILE"
    elif [ -n "$airflow_version" ] && [ "$airflow_version" != "not set" ]; then
      major=${airflow_version%%.*}
      if [ "$major" -lt 2 ]; then
        printf '{"title":"Cloud Composer environment `%s` uses a non-LTS Airflow version","expected":"Cloud Composer environment `%s` should run an LTS supported Airflow version (2.x)","actual":"Cloud Composer environment `%s` runs Airflow `%s`, which is not an LTS version","severity":3,"details":"Environment `%s` in location `%s` of project `%s` runs image `%s` with Airflow `%s`. Outdated Airflow versions are unsupported and may miss critical patches.","next_steps":"Upgrade to a supported LTS Airflow version (2.x) via `gcloud composer environments update` and validate DAG compatibility before the change window.","environment":"%s","airflow_version":"%s","issue_type":"airflow_version_outdated"}\n' \
          "$short_name" "$short_name" "$short_name" "$airflow_version" \
          "$short_name" "$location" "$GCP_PROJECT_ID" "$image_version" "$airflow_version" "$short_name" "$airflow_version" >> "$TMP_FILE"
      fi
    fi
  fi

  # Flag environments that do not expose a web server / Airflow UI URL.
  if [ -z "$airflow_uri" ]; then
    printf '{"title":"Cloud Composer environment `%s` has no Airflow web server URI","expected":"Cloud Composer environment `%s` should expose an Airflow web server URI","actual":"Cloud Composer environment `%s` does not expose an Airflow web server URI","severity":2,"details":"Environment `%s` in location `%s` of project `%s` returned no Airflow web server URI, which may prevent Airflow-level interaction and monitoring.","next_steps":"Confirm the web server is enabled and operational in the environment configuration, then verify network access to the Airflow URI.","environment":"%s","issue_type":"missing_airflow_uri"}\n' \
      "$short_name" "$short_name" "$short_name" "$short_name" "$location" "$GCP_PROJECT_ID" "$short_name" >> "$TMP_FILE"
  fi
done

if [ -s "$TMP_FILE" ]; then
  jq -s '.' "$TMP_FILE" > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi
rm -f "$TMP_FILE"
jq -s '.' "$REPORT_FILE" > "${REPORT_FILE}.merge" && mv "${REPORT_FILE}.merge" "$REPORT_FILE"

echo "Configuration fetch complete. $(jq length "$OUTPUT_FILE") configuration issue(s), $(jq length "$REPORT_FILE") environment(s) dumped."
