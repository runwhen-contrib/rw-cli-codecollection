#!/bin/bash

# Set your project ID
project_id=$PROJECT_ID
project_number=$(gcloud projects describe "$project_id" --format="value(projectNumber)")
declare -a all_service_accounts
declare -a sa_missing_permissions

# Function to check if a service account has a specific permission
# $1: project_id
# $2: service_account
# $3: permission
service_account_has_permission() {
  local project_id="$1"
  local service_account="$2"
  local permission="$3"

  local roles=$(gcloud projects get-iam-policy "$project_id" \
          --flatten="bindings[].members" \
          --format="table[no-heading](bindings.role)" \
          --filter="bindings.members:\"$service_account\"")

  for role in $roles; do
    if role_has_permission "$role" "$permission"; then
      echo "Yes" # Has permission
      return
    fi
  done

  echo "No" # Does not have permission
}

# Function to check if a role has the specific permission
# $1: role
# $2: permission
role_has_permission() {
  local role="$1"
  local permission="$2"
  gcloud iam roles describe "$role" --format="json" | \
  jq -r ".includedPermissions" | \
  grep -q "$permission"
}


echo "--- 1. List all service accounts in all GKE node pools"
printf "%-60s| %-40s| %-40s| %-10s| %-20s\n" "service_account" "project_id" "cluster_name" "cluster_location" "nodepool_name"
while read cluster; do
  cluster_name=$(echo "$cluster" | awk '{print $1}')
  cluster_location=$(echo "$cluster" | awk '{print $2}')

  while read nodepool; do
    nodepool_name=$(echo "$nodepool" | awk '{print $1}')

    while read nodepool_details; do
      service_account=$(echo "$nodepool_details" | awk '{print $1}')

      if [[ "$service_account" == "default" ]]; then
        service_account="${project_number}-compute@developer.gserviceaccount.com"
      fi
      if [[ -n "$service_account" ]]; then
        printf "%-60s| %-40s| %-40s| %-10s| %-20s\n" $service_account $project_id  $cluster_name $cluster_location $nodepool_name
        all_service_accounts+=( ${service_account} )
      else
        echo "cannot find service account" for node pool "$project_id\t$cluster_name\t$cluster_location\t$nodepool_details"
      fi
    done <<< "$(gcloud container node-pools describe "$nodepool_name" --cluster "$cluster_name" --zone "$cluster_location" --project "$project_id" --format="table[no-heading](config.serviceAccount)")"
  done <<< "$(gcloud container node-pools list --cluster "$cluster_name" --zone "$cluster_location" --project "$project_id" --format="table[no-heading](name)")"
done <<< "$(gcloud container clusters list --project "$project_id" --format="value(name,location)")"

echo "--- 2. Check if service accounts have permissions"
unique_service_accounts=($(echo "${all_service_accounts[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

echo "Service accounts: ${unique_service_accounts[@]}"
printf "%-60s| %-40s| %-40s| %-20s\n" "service_account" "has_logging_permission" "has_monitoring_permission" "has_performance_hpa_metric_write_permission"
for sa in "${unique_service_accounts[@]}"; do
  logging_permission=$(service_account_has_permission "$project_id" "$sa" "logging.logEntries.create")
  monitoring_permission=$(service_account_has_permission "$project_id" "$sa" "monitoring.timeSeries.create")
  performance_hpa_metric_write_permission=$(service_account_has_permission "$project_id" "$sa" "autoscaling.sites.writeMetrics")
  printf "%-60s| %-40s| %-40s| %-20s\n" $sa $logging_permission $monitoring_permission $performance_hpa_metric_write_permission

  if [[ "$logging_permission" == "No" || "$monitoring_permission" == "No" || "$performance_hpa_metric_write_permission" == "No" ]]; then
    sa_missing_permissions+=( ${sa} )
  fi
done

echo "--- 3. List all service accounts that don't have the above permissions"
if [[ "${#sa_missing_permissions[@]}" -gt 0 ]]; then
  printf "Grant roles/container.defaultNodeServiceAccount to the following service accounts: %s\n" "${sa_missing_permissions[@]}"
else
  echo "All service accounts have the above permissions"
fi