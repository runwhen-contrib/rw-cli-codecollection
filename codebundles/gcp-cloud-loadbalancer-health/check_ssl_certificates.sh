#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check SSL Certificate Expiry for HTTPS/SSL Load Balancers
#
# For all HTTPS and SSL proxy load balancers, inspects the mapped SSL
# certificates and flags any that will expire within SSL_WARNING_DAYS days,
# reporting days remaining per certificate.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID    - GCP project ID hosting the load balancers
#   SSL_WARNING_DAYS  - Days before expiry to flag the certificate (default 30)
#
# OUTPUTS:
#   ssl_certificate_issues.json - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${SSL_WARNING_DAYS:=30}"

ISSUES_FILE="ssl_certificate_issues.json"
issues_json='[]'
# shellcheck disable=SC2012
now_epoch=$(date +%s)

echo "Checking SSL certificate expiry for project: $GCP_PROJECT_ID (warning threshold: ${SSL_WARNING_DAYS} days)"

# Use discovery dump if present, otherwise list forwarding rules directly.
if [ -f "lb_config.json" ]; then
    lbs=$(cat lb_config.json)
else
    lbs=$(gcloud compute forwarding-rules list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
fi

case "$lbs" in
  *"HTTPS"*|*"SSL"*) ;;
  *) echo "No HTTPS or SSL proxy load balancers found. Nothing to check."; echo "[]" > "$ISSUES_FILE"; exit 0 ;;
esac

# Iterate over each HTTPS/SSL load balancer and resolve its certificates.
while read -r lb; do
    lb_name=$(echo "$lb" | jq -r '.name')
    lb_type=$(echo "$lb" | jq -r '.type')
    target_proxy=$(echo "$lb" | jq -r '.target_proxy // ""')
    target_url=$(echo "$lb" | jq -r '.target // ""')

    if [ -z "$target_proxy" ] || [ "$target_proxy" = "null" ] || [ -z "$lb" ]; then
        continue
    fi

    scope_flags=""
    cert_scope_flags=""
    if echo "$target_url" | grep -q "/regions/"; then
        region_from_target=$(echo "$target_url" | grep -oP '/regions/\K[^/]+')
        scope_flags="--region=$region_from_target"
        cert_scope_flags="--region=$region_from_target"
    fi

    # Resolve the sslCertificate URLs from the target proxy.
    cert_urls="[]"
    if [ "$lb_type" = "HTTPS" ]; then
        cert_urls=$(gcloud compute target-https-proxies describe "$target_proxy" \
            --project="$GCP_PROJECT_ID" $scope_flags --format='json(sslCertificates)' \
            2>/dev/null | jq '.sslCertificates // []' || echo "[]")
    else
        cert_urls=$(gcloud compute target-ssl-proxies describe "$target_proxy" \
            --project="$GCP_PROJECT_ID" --format='json(sslCertificates)' \
            2>/dev/null | jq '.sslCertificates // []' || echo "[]")
    fi

    if [ "$(echo "$cert_urls" | jq length)" -eq 0 ]; then
        continue
    fi

    echo "$cert_urls" | jq -r '.[] | split("/") | .[-1]' | while read -r cert_name; do
        cert=$(gcloud compute ssl-certificates describe "$cert_name" \
            --project="$GCP_PROJECT_ID" $cert_scope_flags --format=json 2>/dev/null || echo "{}")
        expire_time=$(echo "$cert" | jq -r '.expireTime // ""')
        if [ -z "$expire_time" ] || [ "$expire_time" = "null" ]; then
            continue
        fi
        # Parse RFC3339 expiry to epoch using GNU date.
        expiry_epoch=$(date -d "$expire_time" +%s 2>/dev/null || echo "")
        if [ -z "$expiry_epoch" ]; then
            continue
        fi
        days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
        echo "  LB '$lb_name' ($lb_type) cert '$cert_name' expires in ${days_left} days"

        if [ "$days_left" -le "$SSL_WARNING_DAYS" ]; then
            severity="2"
            if [ "$days_left" -lt 0 ]; then
                severity="3"
            fi
            issue=$(jq -n \
                --arg title "SSL certificate \`$cert_name\` for load balancer \`$lb_name\` expires in ${days_left} days" \
                --arg details "Load balancer '$lb_name' ($lb_type) in project '$GCP_PROJECT_ID' uses SSL certificate '$cert_name' ($expire_time) which expires in $days_left day(s). Traffic will fail once the certificate expires." \
                --arg severity "$severity" \
                --arg expected "All SSL certificates should be valid for more than $SSL_WARNING_DAYS days" \
                --arg actual "Certificate '$cert_name' expires in $days_left days (threshold: $SSL_WARNING_DAYS days)" \
                --arg next_steps "Renew or replace certificate '$cert_name' before it expires. See: gcloud compute ssl-certificates describe $cert_name --project=$GCP_PROJECT_ID. Renew via Certificate Manager or re-upload a new cert." \
                '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
            issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
            echo "$issues_json" > "$ISSUES_FILE"
        fi
    done
done < <(echo "$lbs" | jq -c '.[] | select(.type == "HTTPS" or .type == "SSL")' 2>/dev/null)

if [ ! -s "$ISSUES_FILE" ]; then
    echo "[]" > "$ISSUES_FILE"
fi

echo "SSL certificate check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
