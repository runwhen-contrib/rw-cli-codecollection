#!/usr/bin/env bash
set -euo pipefail
set -x

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
# OPTIONAL ENV VARS:
#   RESOURCES  (comma-separated instance name filter; "All")
#
# This script flags Cloud SQL instances that are reachable from the public
# internet, missing SSL enforcement, expose authorized networks, or have
# IP/environment issues affecting availability.
# It writes a JSON array of issues to instance_access_issues.json.
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${RESOURCES:=All}"

OUTPUT_FILE="instance_access_issues.json"

echo "Checking Cloud SQL instance availability and access for project: $GCP_PROJECT_ID"

instances=$(gcloud sql instances list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
if [ "$(echo "$instances" | jq length)" -eq 0 ]; then
  echo "No Cloud SQL instances found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

if [ "$RESOURCES" != "All" ] && [ -n "$RESOURCES" ]; then
  filter=$(echo "$RESOURCES" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | paste -sd'|' -)
  if [ -z "$filter" ]; then
    filter="NEVER_MATCHES"
  fi
  instances=$(echo "$instances" | jq --arg f "$filter" '[.[] | select(.name | test($f))]')
fi

if [ "$(echo "$instances" | jq length)" -eq 0 ]; then
  echo "No matching instances found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

> "$OUTPUT_FILE"

echo "$instances" | jq -c '.[]' | while read -r inst; do
  name=$(echo "$inst" | jq -r '.name // "unknown"')

  echo "Checking access for $name"
  cfg=$(gcloud sql instances describe "$name" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "{}")

  ipv4_enabled=$(echo "$cfg" | jq -r '.settings.ipConfiguration.ipv4Enabled // false')
  require_ssl=$(echo "$cfg" | jq -r '.settings.ipConfiguration.requireSsl // false')
  public_ip=$(echo "$cfg" | jq -r '[.ipAddresses[]? | select(.type == "PRIMARY" or .type == "EXTERNAL")] | length')
  private_ip=$(echo "$cfg" | jq -r '.privateIpAddress // ""')
  num_networks=$(echo "$cfg" | jq '[.settings.ipConfiguration.authorizedNetworks[]?] | length')
  wildcard_networks=$(echo "$cfg" | jq '[.settings.ipConfiguration.authorizedNetworks[]? | select(.value == "0.0.0.0/0")] | length')

  echo "  $name ipv4=$ipv4_enabled ssl=$require_ssl public_ip=$public_ip private_ip=$private_ip networks=$num_networks"

  # 1) Public internet exposure via IPv4.
  if [ "$ipv4_enabled" = "true" ] && [ "$public_ip" -gt 0 ]; then
    printf '{"title":"Cloud SQL instance `%s` is exposed to the public internet","details":"Cloud SQL instance `%s` in project `%s` has a public IPv4 address and IPv4 connectivity enabled, making it reachable from the internet.","severity":4,"expected":"Instances should not be reachable from the public internet","actual":"Instance has public IPv4 connectivity enabled","next_steps":"Disable public IP or restrict to a private IP: gcloud sql instances patch %s --no-assign-ip --project=%s. If public access is required, restrict authorized networks and enforce SSL.","instance":"%s","issue_type":"public_internet_exposure"}\n' \
      "$name" "$name" "$GCP_PROJECT_ID" "$name" "$GCP_PROJECT_ID" "$name" >> "$OUTPUT_FILE"
  fi

  # 2) SSL not enforced when publicly reachable.
  if [ "$ipv4_enabled" = "true" ] && [ "$require_ssl" != "true" ]; then
    printf '{"title":"Cloud SQL instance `%s` does not enforce SSL","details":"Cloud SQL instance `%s` in project `%s` has public connectivity but SSL enforcement is disabled, allowing unencrypted connections.","severity":3,"expected":"SSL should be required for connections","actual":"SSL is not enforced","next_steps":"Enforce SSL: gcloud sql instances patch %s --require-ssl --project=%s.","instance":"%s","issue_type":"ssl_not_enforced"}\n' \
      "$name" "$name" "$GCP_PROJECT_ID" "$name" "$GCP_PROJECT_ID" "$name" >> "$OUTPUT_FILE"
  fi

  # 3) Authorized network open to the entire internet.
  if [ "$wildcard_networks" -gt 0 ]; then
    printf '{"title":"Cloud SQL instance `%s` allows access from any IP","details":"Cloud SQL instance `%s` in project `%s` has an authorized network of 0.0.0.0/0, allowing connections from any IP address.","severity":3,"expected":"Authorized networks should be restricted to trusted IP ranges","actual":"Instance allows access from 0.0.0.0/0","next_steps":"Remove the wildcard authorized network and add only trusted CIDR ranges.","instance":"%s","issue_type":"exposed_authorized_network"}\n' \
      "$name" "$name" "$GCP_PROJECT_ID" "$name" >> "$OUTPUT_FILE"
  fi

  # 4) Availability issue: no usable IP configured (neither public nor private).
  if [ "$public_ip" -eq 0 ] && [ -z "$private_ip" ]; then
    printf '{"title":"Cloud SQL instance `%s` has no configured IP address","details":"Cloud SQL instance `%s` in project `%s` has neither a public nor a private IP address, so applications cannot connect to it.","severity":3,"expected":"Instance should have a reachable IP address","actual":"Instance has no IP address configured","next_steps":"Assign a private IP (or public IP if appropriate): gcloud sql instances patch %s --assign-ip --project=%s and reconfigure authorized networks as needed.","instance":"%s","issue_type":"no_usable_ip"}\n' \
      "$name" "$name" "$GCP_PROJECT_ID" "$name" "$GCP_PROJECT_ID" "$name" >> "$OUTPUT_FILE"
  fi
done

if [ -s "$OUTPUT_FILE" ]; then
  jq -s '.' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "Access check complete. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
