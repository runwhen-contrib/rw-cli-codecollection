#!/usr/bin/env bash
set -euo pipefail
set -x

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AUTH0_TENANT
#   AUTH0_MGMT_CREDENTIALS
#   LOG_LOOKBACK_HOURS          (default 24)
#   LOGIN_FAILURE_THRESHOLD     (default 50)
#   RATE_LIMIT_THRESHOLD_PCT    (default 80)
#   CERT_EXPIRY_WARN_DAYS       (default 30)
#
# Lightweight health scorer for the Auth0 tenant SLI. Produces a JSON object on
# stdout with a 0/1 score per dimension used by sli.robot:
#   {
#     "service_availability": 0/1,
#     "custom_domains":        0/1,
#     "error_logs":            0/1,
#     "login_failures":        0/1,
#     "rate_limits":           0/1,
#     "log_streams":           0/1
#   }
# A dimension scores 1 when healthy and 0 when degraded.
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/auth0_helpers.sh"

: "${LOG_LOOKBACK_HOURS:=24}"
: "${LOGIN_FAILURE_THRESHOLD:=50}"
: "${RATE_LIMIT_THRESHOLD_PCT:=80}"
: "${CERT_EXPIRY_WARN_DAYS:=30}"

from_ts="$(date -u -d "${LOG_LOOKBACK_HOURS} hours ago" +%Y%m%dT%H%M%S00Z 2>/dev/null || echo "19700101T000000Z")"

# --- Dimension 1: service availability (well-known endpoint reachable) ---
avail_http=$(curl -sS -o /tmp/auth0sli_disc.json -w "%{http_code}" --max-time 20 \
    "${AUTH0_BASE_URL}/.well-known/openid-configuration" || true)
if [ "${avail_http}" = "200" ]; then
    service_availability=1
else
    service_availability=0
fi
echo "dimension service_availability: http=${avail_http} score=${service_availability}"
rm -f /tmp/auth0sli_disc.json

# --- Dimension 2: custom domains verified & certs not expiring ---
custom_domains=1
domains_raw="$(auth0_get "$(auth0_mgmt_url "custom-domains")" || echo '[]')"
if echo "${domains_raw}" | jq -e 'type == "array"' >/dev/null 2>&1; then
    while IFS= read -r dom; do
        [ -z "${dom}" ] && continue
        st="$(echo "${dom}" | jq -r '.status // "unknown"')"
        nm="$(echo "${dom}" | jq -r '.domain // empty')"
        if [ "${st}" != "verified" ] && [ "${st}" != "disabled" ]; then
            custom_domains=0
            echo "custom_domains degraded by domain ${nm} (status ${st})"
            continue
        fi
        # Certificate expiry via openssl
        if command -v openssl >/dev/null 2>&1 && [ -n "${nm}" ]; then
            end_date="$(timeout 15 openssl s_client -servername "${nm}" -connect "${nm}:443" </dev/null 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | grep -i '^notAfter=' | cut -d= -f2 || true)"
            if [ -n "${end_date}" ]; then
                exp="$(date -d "${end_date}" +%s 2>/dev/null || echo 0)"
                now="$(date +%s)"
                if [ -n "${exp}" ] && [ "${exp}" -gt "${now}" ]; then
                    days=$(( (exp - now) / 86400 ))
                    if [ "${days}" -le "${CERT_EXPIRY_WARN_DAYS}" ]; then
                        custom_domains=0
                        echo "custom_domains degraded: ${nm} cert expires in ${days} days"
                    fi
                else
                    custom_domains=0
                    echo "custom_domains degraded: ${nm} cert expired"
                fi
            fi
        fi
    done < <(echo "${domains_raw}" | jq -c '.[]')
fi
echo "dimension custom_domains score=${custom_domains}"

# --- Dimension 3: error log spike absence ---
error_logs=1
logs_raw="$(auth0_get "$(auth0_mgmt_url "logs")" \
    "sort=date:desc" "per_page=100" "q=date:[${from_ts} TO NOW]" || echo '[]')"
if echo "${logs_raw}" | jq -e 'type == "array"' >/dev/null 2>&1; then
    err_count="$(echo "${logs_raw}" | jq '[.[] | select(.type_name | test("^f|failed|error|anomaly|block|mfa"; "i"))] | length' 2>/dev/null || echo 0)"
else
    err_count=0
fi
if [ "${err_count:-0}" -ge 3 ]; then
    error_logs=0
fi
echo "dimension error_logs err_count=${err_count:-0} score=${error_logs}"

# --- Dimension 4: login failure threshold not breached ---
login_failures=1
if [ -n "${err_count:-0}" ]; then
    if [ "${err_count}" -ge "${LOGIN_FAILURE_THRESHOLD}" ]; then
        login_failures=0
    fi
fi
echo "dimension login_failures score=${login_failures}"

# --- Dimension 5: no sustained rate-limit signals / high utilization ---
rate_limits=1
limit_logs="$(auth0_get "$(auth0_mgmt_url "logs")" \
    "sort=date:desc" "per_page=100" "q=type.limit OR type:limitw AND date:[${from_ts} TO NOW]" || echo '[]')"
limit_count=0
if echo "${limit_logs}" | jq -e 'type == "array"' >/dev/null 2>&1; then
    limit_count="$(echo "${limit_logs}" | jq 'length')"
fi
if [ -n "${limit_count}" ] && [ "${limit_count}" -gt 0 ]; then
    rate_limits=0
fi
echo "dimension rate_limits limit_count=${limit_count} score=${rate_limits}"

# --- Dimension 6: log streams active (if configured) ---
log_streams=1
streams_raw="$(auth0_get "$(auth0_mgmt_url "log-streams")" || echo '[]')"
if echo "${streams_raw}" | jq -e 'type == "array"' >/dev/null 2>&1; then
    sc="$(echo "${streams_raw}" | jq 'length')"
    if [ "${sc}" -gt 0 ]; then
        if echo "${streams_raw}" | jq -e '.[] | select(.status != "active" and .status != "empty")' >/dev/null 2>&1; then
            log_streams=0
            echo "log_streams degraded: one or more streams inactive"
        fi
    fi
fi
echo "dimension log_streams score=${log_streams}"

jq -n \
    --argjson service_availability "${service_availability}" \
    --argjson custom_domains "${custom_domains}" \
    --argjson error_logs "${error_logs}" \
    --argjson login_failures "${login_failures}" \
    --argjson rate_limits "${rate_limits}" \
    --argjson log_streams "${log_streams}" \
    '{service_availability: $service_availability, custom_domains: $custom_domains, error_logs: $error_logs, login_failures: $login_failures, rate_limits: $rate_limits, log_streams: $log_streams}'