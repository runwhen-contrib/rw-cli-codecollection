#!/usr/bin/env bash
set -euo pipefail
set -x

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AUTH0_TENANT
#   AUTH0_MGMT_CREDENTIALS
#   CERT_EXPIRY_WARN_DAYS  (default 30)
#
# This script validates each configured custom domain via the Custom Domains
# API:
#   1) Lists custom domains
#   2) Checks DNS resolution of each domain
#   3) Checks TLS certificate validity/expiry (days before expiry)
#   4) Checks the domain verification status
# Outputs a JSON array of issues to OUTPUT_FILE.
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/auth0_helpers.sh"

: "${CERT_EXPIRY_WARN_DAYS:=30}"

OUTPUT_FILE="custom_domain_issues.json"
issues_json='[]'

echo "Checking custom domain health for tenant: ${AUTH0_TENANT}"

domains_raw="$(auth0_get "$(auth0_mgmt_url "custom-domains")" || echo '[]')"

if ! echo "${domains_raw}" | jq -e 'type == "array"' >/dev/null 2>&1; then
    # Empty or error response -> no configured custom domains (non-fatal)
    echo "No custom domains returned (response type check failed). Assuming none configured."
    echo "${issues_json}" > "${OUTPUT_FILE}"
    exit 0
fi

domain_count="$(echo "${domains_raw}" | jq 'length')"
echo "Configured custom domains: ${domain_count}"

if [ "${domain_count}" -eq 0 ]; then
    echo "No custom domains configured for tenant ${AUTH0_TENANT}. Nothing to validate."
    echo "${issues_json}" > "${OUTPUT_FILE}"
    exit 0
fi

while IFS= read -r domain; do
    [ -z "${domain}" ] && continue
    id="$(echo "${domain}" | jq -r '.id // empty')"
    name="$(echo "${domain}" | jq -r '.domain // empty')"
    status="$(echo "${domain}" | jq -r '.status // "unknown"')"
    [ -z "${name}" ] && continue

    echo "Analyzing custom domain: ${name} (status: ${status})"

    # --- Verification status ---
    if [ "${status}" != "verified" ] && [ "${status}" != "disabled" ]; then
        issues_json=$(echo "${issues_json}" | jq \
            --arg domain "${name}" \
            --arg tenant "${AUTH0_TENANT}" \
            --arg st "${status}" \
            --arg title "Custom Domain Not Verified for \`${name}\`" \
            --arg details "Custom domain '${name}' on tenant ${AUTH0_TENANT} has verification status '${status}'. Expected 'verified'." \
            --argjson severity 2 \
            --arg next_steps "Complete the Custom Domains verification flow in the Auth0 dashboard for ${name} (DNS TXT/CNAME challenge)." \
            '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
    fi

    # --- DNS resolution ---
    resolved=""
    if getent hosts "${name}" >/dev/null 2>&1; then
        resolved="ok"
    fi
    if [ -z "${resolved}" ]; then
        issues_json=$(echo "${issues_json}" | jq \
            --arg title "Custom Domain DNS Does Not Resolve for \`${name}\`" \
            --arg details "DNS lookup for '${name}' failed. The domain may not be pointed at the Auth0 edge." \
            --argjson severity 2 \
            --arg next_steps "Ensure ${name} has the required DNS records (CNAME/A) pointing to the Auth0 domain edge." \
            '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
    else
        echo "DNS resolution OK for ${name}"
    fi

    # --- TLS certificate validity/expiry ---
    if command -v openssl >/dev/null 2>&1 && [ "${resolved}" = "ok" ]; then
        cert_dates="$(timeout 20 openssl s_client -servername "${name}" -connect "${name}:443" </dev/null 2>/dev/null \
            | openssl x509 -noout -enddate 2>/dev/null || true)"
        end_date="$(echo "${cert_dates}" | grep -i '^notAfter=' | cut -d= -f2 || true)"
        if [ -z "${end_date}" ]; then
            issues_json=$(echo "${issues_json}" | jq \
                --arg title "Custom Domain TLS Certificate Unreadable for \`${name}\`" \
                --arg details "Could not read the TLS certificate end date for ${name}:443." \
                --argjson severity 2 \
                --arg next_steps "Verify an HTTPS endpoint is serving on ${name}:443 with a valid certificate." \
                '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
        else
            expiry_epoch="$(date -d "${end_date}" +%s 2>/dev/null || echo "0")"
            now_epoch="$(date +%s)"
            if [ -n "${expiry_epoch}" ] && [ "${expiry_epoch}" -ne 0 ]; then
                days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
                echo "Certificate for ${name}: notAfter=${end_date}, days_left=${days_left}"
                if [ "${days_left}" -lt 0 ]; then
                    issues_json=$(echo "${issues_json}" | jq \
                        --arg title "Custom Domain Certificate Expired for \`${name}\`" \
                        --arg details "TLS certificate for ${name} expired on ${end_date}. Users cannot reach the login domain over HTTPS." \
                        --argjson severity 2 \
                        --arg next_steps "Renew the custom domain certificate immediately in Auth0 (custom domains auto-manage certs; verify)." \
                        '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
                elif [ "${days_left}" -le "${CERT_EXPIRY_WARN_DAYS}" ]; then
                    issues_json=$(echo "${issues_json}" | jq \
                        --arg title "Custom Domain Certificate Expiring Soon for \`${name}\`" \
                        --arg details "TLS certificate for ${name} expires in ${days_left} days (${end_date}). Threshold: ${CERT_EXPIRY_WARN_DAYS} days." \
                        --argjson severity 3 \
                        --arg next_steps "Confirm Auth0 auto-managed certificate renewal is active or renew the certificate." \
                        '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
                fi
            fi
        fi
    fi
done < <(echo "${domains_raw}" | jq -c '.[]')

issues_json=$(echo "${issues_json}" | jq 'sort_by(.severity)')
echo "${issues_json}" > "${OUTPUT_FILE}"
echo "Custom domain health check completed. Results saved to ${OUTPUT_FILE}"