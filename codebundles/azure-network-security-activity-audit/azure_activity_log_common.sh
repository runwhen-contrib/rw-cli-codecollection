#!/usr/bin/env bash
# Shared helpers for Azure Network activity audit scripts (sourced, not run directly).
# shellcheck shell=bash

activity_compute_times() {
  local hours="${ACTIVITY_LOOKBACK_HOURS:-168}"
  export ACTIVITY_START_TIME
  export ACTIVITY_END_TIME
  ACTIVITY_START_TIME=$(date -u -d "${hours} hours ago" '+%Y-%m-%dT%H:%M:%SZ')
  ACTIVITY_END_TIME=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
}

activity_az_base_args() {
  # shellcheck disable=SC2207
  ACTIVITY_AZ_ARGS=(--subscription "${AZURE_SUBSCRIPTION_ID}" --namespace Microsoft.Network
    --start-time "${ACTIVITY_START_TIME}" --end-time "${ACTIVITY_END_TIME}" --max-events 500 -o json)
  if [[ -n "${AZURE_RESOURCE_GROUP:-}" ]]; then
    ACTIVITY_AZ_ARGS+=(--resource-group "${AZURE_RESOURCE_GROUP}")
  fi
}

activity_fetch_network_events() {
  activity_compute_times
  activity_az_base_args
  if ! az monitor activity-log list "${ACTIVITY_AZ_ARGS[@]}" 2>activity_err.log; then
    cat activity_err.log >&2
    echo "[]"
    return 1
  fi
  rm -f activity_err.log
  return 0
}
