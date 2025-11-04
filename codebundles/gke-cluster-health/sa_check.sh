#!/bin/bash

project_id="$GCP_PROJECT_ID"
project_number=$(gcloud projects describe "$project_id" --format="value(projectNumber)")

# Arrays to track service accounts
declare -a all_service_accounts
declare -A sa_missing_map  # Map of SA -> missingPermissions array

#----------------------
# FUNCTION DEFINITIONS
#----------------------

# Checks if a service account has a specific permission
# $1: project_id
# $2: service_account
# $3: permission
service_account_has_permission() {
  local project_id="$1"
  local service_account="$2"
  local permission="$3"

  # Get all roles for the service account in this project
  local roles
  roles=$(gcloud projects get-iam-policy "$project_id" \
          --flatten="bindings[].members" \
          --format="table[no-heading](bindings.role)" \
          --filter="bindings.members:\"$service_account\"")

  # Check each role to see if it grants the given permission
  for role in $roles; do
    if role_has_permission "$role" "$permission"; then
      echo "Yes"
      return
    fi
  done

  echo "No"
}

# Checks if a given custom or predefined role has a specific permission
# $1: role
# $2: permission
role_has_permission() {
  local role="$1"
  local permission="$2"

  gcloud iam roles describe "$role" --format="json" 2>/dev/null | \
    jq -r ".includedPermissions[]" 2>/dev/null | \
    grep -qx "$permission"
}

#---------------
# MAIN LOGIC
#---------------

# 1. List all service accounts in all GKE node pools
echo "==============================================================="
echo "1. List all service accounts used by GKE node pools"
echo "==============================================================="

# Print table header with nice spacing
printf "%-60s | %-30s | %-25s | %-15s | %-15s\n" \
  "SERVICE_ACCOUNT" "PROJECT_ID" "CLUSTER_NAME" "CLUSTER_LOCATION" "NODEPOOL_NAME"
echo "-----------------------------------------------------------------------------------------------"

while read -r cluster; do
  cluster_name=$(echo "$cluster" | awk '{print $1}')
  cluster_location=$(echo "$cluster" | awk '{print $2}')

  # For each cluster, list its node pools
  while read -r nodepool; do
    nodepool_name=$(echo "$nodepool" | awk '{print $1}')

    # Grab the serviceAccount line from node pool details
    while read -r nodepool_details; do
      service_account=$(echo "$nodepool_details" | awk '{print $1}')

      # If no custom SA is defined, default to the Compute default
      if [[ "$service_account" == "default" ]]; then
        service_account="${project_number}-compute@developer.gserviceaccount.com"
      fi

      if [[ -n "$service_account" ]]; then
        printf "%-60s | %-30s | %-25s | %-15s | %-15s\n" \
          "$service_account" \
          "$project_id" \
          "$cluster_name" \
          "$cluster_location" \
          "$nodepool_name"
        all_service_accounts+=( "$service_account" )
      else
        echo "Cannot find service account for node pool: $project_id $cluster_name $cluster_location $nodepool_details"
      fi
    done <<< "$(gcloud container node-pools describe "$nodepool_name" \
                --cluster "$cluster_name" \
                --zone "$cluster_location" \
                --project "$project_id" \
                --format="table[no-heading](config.serviceAccount)")"
  done <<< "$(gcloud container node-pools list \
              --cluster "$cluster_name" \
              --zone "$cluster_location" \
              --project "$project_id" \
              --format="table[no-heading](name)")"
done <<< "$(gcloud container clusters list \
            --project "$project_id" \
            --format="value(name,location)")"

# 2. Check if service accounts have certain permissions
echo
echo "==============================================================="
echo "2. Check if service accounts have required permissions"
echo "==============================================================="

# Get unique service accounts
IFS=$'\n' unique_service_accounts=($(echo "${all_service_accounts[*]}" | sort -u))
unset IFS

echo "Service accounts discovered: ${unique_service_accounts[*]}"
echo

# Print table header
printf "%-60s | %-10s | %-10s | %-10s\n" \
  "SERVICE_ACCOUNT" "LOGGING" "MONITOR" "AUTO-HPA"
echo "-------------------------------------------------------------------"

for sa in "${unique_service_accounts[@]}"; do
  # Check each required permission
  logging_permission=$(service_account_has_permission "$project_id" "$sa" "logging.logEntries.create")
  monitoring_permission=$(service_account_has_permission "$project_id" "$sa" "monitoring.timeSeries.create")
  performance_hpa_metric_write_permission=$(service_account_has_permission "$project_id" "$sa" "autoscaling.sites.writeMetrics")

  # Print row
  printf "%-60s | %-10s | %-10s | %-10s\n" \
    "$sa" \
    "$logging_permission" \
    "$monitoring_permission" \
    "$performance_hpa_metric_write_permission"

  # Track missing permissions in a map (SA -> array of missing perms)
  if [[ "$logging_permission" == "No" || "$monitoring_permission" == "No" || "$performance_hpa_metric_write_permission" == "No" ]]; then
    # Build an array of what's missing for this SA
    missing=()
    [[ "$logging_permission" == "No" ]] && missing+=("logging.logEntries.create")
    [[ "$monitoring_permission" == "No" ]] && missing+=("monitoring.timeSeries.create")
    [[ "$performance_hpa_metric_write_permission" == "No" ]] && missing+=("autoscaling.sites.writeMetrics")

    sa_missing_map["$sa"]="${missing[*]}"
  fi
done

# 3. Print a summary of missing permissions
echo
echo "==============================================================="
echo "3. Service accounts missing permissions (if any)"
echo "==============================================================="

if [[ ${#sa_missing_map[@]} -eq 0 ]]; then
  echo "All service accounts have the required permissions."
else
  echo "The following service accounts are missing permissions:"
  for sa in "${!sa_missing_map[@]}"; do
    echo "- $sa is missing: ${sa_missing_map[$sa]}"
  done

  echo
  echo "Suggested fix:"
  echo "  Grant 'roles/container.defaultNodeServiceAccount' or other appropriate roles"
  echo "  to each service account that is missing permissions."
fi

# 4. Generate issues.json if there are missing permissions
echo
echo "==============================================================="
echo "4. Generating issues.json for missing permissions"
echo "==============================================================="

json_file="issues.json"

if [[ ${#sa_missing_map[@]} -eq 0 ]]; then
  # Write an empty issues array
  cat <<EOF > "$json_file"
{
  "issues": []
}
EOF

  echo "No issues found. Created empty $json_file."
else
  # Build JSON array of issues
  echo "{" > "$json_file"
  echo "  \"issues\": [" >> "$json_file"

  counter=0
  total=$(( ${#sa_missing_map[@]} - 1 ))
  for sa in "${!sa_missing_map[@]}"; do
    missing_perms=${sa_missing_map[$sa]}

    title="Service account missing permissions: $sa"
    details="The service account $sa is missing the following permissions: $missing_perms"
    severity="2"
    next_steps="Grant 'roles/container.defaultNodeServiceAccount' or other appropriate roles to fix these permissions."

    summary="The service account $sa in \`$cluster_name\` is missing the following \
permissions: $missing_perms. The expected behavior is that service accounts have all \
necessary permissions, but this was not met. Action is needed to grant \
'roles/container.defaultNodeServiceAccount' or another appropriate role, review audit \
logs, inspect autoscaling dependencies, and analyze failed metric write attempts in \`$cluster_name\`."

    observations=$(jq -nc \
      --arg cluster "$cluster_name" \
      --arg sa "$sa" \
      '[
        {
          "category": "security",
          "observation": ("The service account `" + $sa + "` is missing the `autoscaling.sites.writeMetrics` permission in `" + $cluster + "`.")
        },
        {
          "category": "operational",
          "observation": ("Audit logs for service account activity in `" + $cluster + "` require review to understand missing permissions.")
        },
        {
          "category": "operational",
          "observation": ("Failed metric write attempts have been detected in `" + $cluster + "` due to insufficient permissions for `" + $sa + "`.")
        }
      ]'
    )

    cat <<EOF >> "$json_file"
    {
      "title": "$title",
      "details": "$details",
      "severity": $severity,
      "next_steps": "$next_steps",
      "summary": "$summary",
      "observations": $observations
    }$( [[ $counter -lt $total ]] && echo "," )
EOF
    ((counter++))
  done

  echo "  ]" >> "$json_file"
  echo "}" >> "$json_file"

  echo "Created $json_file with missing-permissions details."
fi
