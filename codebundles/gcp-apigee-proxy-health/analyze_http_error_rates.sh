#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# analyze_http_error_rates.sh
# Queries Analytics metrics by response_status_code for 401/403/429 rates.
# Flags 401/403 rate elevated (token validation failure, API product mismatch,
# expired developer app credentials) and 429 rate elevated beyond the intended
# quota / spike-arrest policy (rejecting legitimate traffic).
#
# Rates are computed per proxy against that proxy's TOTAL request count across
# all status codes, aggregated over every environment in the org.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID          - GCP project owning the Apigee org
#   APIGEE_ORG              - optional; Apigee org (resolved if empty)
#   AUTH_ERROR_RATE_THRESHOLD   - max 401/403 rate (default 0.02)
#   RATE_LIMIT_ERROR_THRESHOLD  - max 429 rate (default 0.05)
#   ANALYTICS_WINDOW_MIN    - lookback window in minutes (default 60)
#
# OUTPUTS:
#   http_error_rate_issues.json - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
AUTH_ERROR_RATE_THRESHOLD="${AUTH_ERROR_RATE_THRESHOLD:-0.02}"
RATE_LIMIT_ERROR_THRESHOLD="${RATE_LIMIT_ERROR_THRESHOLD:-0.05}"
ANALYTICS_WINDOW_MIN="${ANALYTICS_WINDOW_MIN:-60}"
PROXIES="${PROXIES:-All}"
# BASH_SOURCE is unset under go-task (mvdan.cc/sh), where dirname "" yields "."
# and silently resolves against the caller's CWD -- one level off for any task
# declaring `dir:`. Fall back to $0, which both shells set.
_apigee_self="${BASH_SOURCE[0]:-$0}"
. "$(cd "$(dirname "$_apigee_self")" && pwd)/apigee_common.sh"

ISSUES_FILE="http_error_rate_issues.json"
apigee_init_issues "$ISSUES_FILE"
apigee_reset_api_errors
issues_json='[]'

if [ -z "$(apigee_access_token)" ]; then
    echo "No access token; skipping HTTP error rate analysis (reported by discovery)."
    exit 0
fi

ORG="$(apigee_org)"
[ -z "$ORG" ] && { echo "Could not resolve org; skipping (reported by discovery)."; exit 0; }

now_epoch=$(date +%s)
start_epoch=$(( now_epoch - (ANALYTICS_WINDOW_MIN * 60) ))
t_start=$(date -u -d "@$start_epoch" "+%m/%d/%Y %H:%M")
t_end=$(date -u -d "@$now_epoch" "+%m/%d/%Y %H:%M")

echo "Analyzing HTTP error rates for org: $ORG (window: ${ANALYTICS_WINDOW_MIN}m, 401/403>${AUTH_ERROR_RATE_THRESHOLD}, 429>${RATE_LIMIT_ERROR_THRESHOLD})"

proxy_filter="$(apigee_expand_csv "$PROXIES")"

environments=$(apigee_list_environments "$ORG")
env_count=$(echo "$environments" | jq length)
if [ "$env_count" -eq 0 ]; then
    echo "No environments resolved for org '$ORG'; cannot analyze Analytics."
    issues_json=$(apigee_append_api_error_issue "$issues_json" "the HTTP error rate analysis")
    echo "$issues_json" > "$ISSUES_FILE"
    exit 0
fi
echo "  Environments in scope: $(echo "$environments" | jq -r 'join(", ")')"

# Counts land in the working directory, not /tmp: the runner preserves this
# directory as the task artifact, and a stale /tmp file from an earlier run in
# the same container would silently join this run's totals.
COUNTS_FILE="http_status_counts.txt"
: > "$COUNTS_FILE"

for env in $(echo "$environments" | jq -r '.[]'); do
    echo "  Querying HTTP error rates for environment '$env'..."
    # Dimension is the composite apiproxy,response_status_code.
    resp=$(apigee_stats "$ORG" "$env" "apiproxy,response_status_code" "sum(message_count)" "$t_start" "$t_end")
    dims=$(printf '%s' "$resp" | apigee_stats_dimensions)

    while read -r dim; do
        proxy=$(apigee_dimension_part "$dim" 0)
        code=$(apigee_dimension_part "$dim" 1)
        [ -z "$proxy" ] && continue
        [ -z "$code" ] && continue
        if [ "$proxy_filter" != "All" ]; then
            echo "$proxy_filter" | tr ',' '\n' | grep -qxF "$proxy" || continue
        fi
        count=$(apigee_metric "$dim" "message_count" sum)
        printf '%s\t%s\t%s\n' "$proxy" "$code" "$count" >> "$COUNTS_FILE"
    done < <(printf '%s' "$dims" | jq -c '.[]')
done

if [ ! -s "$COUNTS_FILE" ]; then
    echo "No HTTP error rate data returned in the lookback window."
    issues_json=$(apigee_append_api_error_issue "$issues_json" "the HTTP error rate analysis")
    echo "$issues_json" > "$ISSUES_FILE"
    exit 0
fi

# Aggregate in awk rather than bash associative arrays: `declare -A` needs
# bash 4+, and this must also run under the bash 3.2 shipped on macOS.
# Emits: proxy<TAB>code<TAB>code_count<TAB>proxy_total for the codes we score.
rates=$(awk -F'\t' '
    { code_count[$1 "\t" $2] += $3; proxy_total[$1] += $3 }
    END {
        for (k in code_count) {
            split(k, parts, "\t")
            p = parts[1]; c = parts[2]
            if (c != "401" && c != "403" && c != "429") continue
            if (proxy_total[p] <= 0) continue
            printf "%s\t%s\t%.0f\t%.0f\n", p, c, code_count[k], proxy_total[p]
        }
    }' "$COUNTS_FILE" | sort)

# 401 and 403 share AUTH_ERROR_RATE_THRESHOLD, so they are one finding
# ("authentication/authorization rejections"); 429 has its own threshold and its
# own remediation, so it stays separate. Previously the 401 and 403 branches
# produced titles differing only by the code -- two issues for one condition.
auth_list=""; auth_n=0
rl_list="";   rl_n=0

while IFS=$'\t' read -r proxy code count total; do
    [ -z "$proxy" ] && continue
    rate=$(awk -v c="$count" -v t="$total" 'BEGIN { printf "%.6f", c/t }')
    echo "  Proxy '$proxy': HTTP $code = $count / $total (rate $rate)"

    case "$code" in
        401|403)
            if [ "$(awk -v r="$rate" -v thr="$AUTH_ERROR_RATE_THRESHOLD" 'BEGIN { print (r > thr) ? 1 : 0 }')" = "1" ]; then
                auth_list="${auth_list}  - ${proxy}: HTTP ${code} rate ${rate} (${count} of ${total} requests)"$'\n'
                auth_n=$((auth_n + 1))
            fi
            ;;
        429)
            if [ "$(awk -v r="$rate" -v thr="$RATE_LIMIT_ERROR_THRESHOLD" 'BEGIN { print (r > thr) ? 1 : 0 }')" = "1" ]; then
                rl_list="${rl_list}  - ${proxy}: HTTP 429 rate ${rate} (${count} of ${total} requests)"$'\n'
                rl_n=$((rl_n + 1))
            fi
            ;;
    esac
done <<< "$rates"

if [ "$auth_n" -gt 0 ]; then
    issues_json=$(echo "$issues_json" | jq --argjson i "$(apigee_make_issue \
        "Apigee proxies are rejecting requests with 401/403 in \`$GCP_PROJECT_ID\`" 3 \
        "The 401/403 rate should remain below AUTH_ERROR_RATE_THRESHOLD" \
        "$auth_n proxy/status pair(s) exceed the auth error threshold" \
        "401/403 indicates token validation failure, API product mismatch, or expired developer app credentials. Diagnose with the gcp-apigee-product-governance bundle: check API product / developer app / credential expiry and the OAuth / verify-api-key policy configuration for the proxies listed." \
        "Threshold: $AUTH_ERROR_RATE_THRESHOLD over the last ${ANALYTICS_WINDOW_MIN}m."$'\n'"$auth_n over threshold:"$'\n'"$auth_list")" '. += [$i]')
fi

if [ "$rl_n" -gt 0 ]; then
    issues_json=$(echo "$issues_json" | jq --argjson i "$(apigee_make_issue \
        "Apigee proxies are rejecting requests with 429 in \`$GCP_PROJECT_ID\`" 3 \
        "The 429 rate should remain below RATE_LIMIT_ERROR_THRESHOLD" \
        "$rl_n proxy(ies) exceed the rate-limit threshold" \
        "The Quota / SpikeArrest policy may be rejecting legitimate traffic, or clients are over the intended limit. Confirm the configured limits match intended capacity for the proxies listed; if the limits are correct, investigate unexpected burst traffic on the API product / developer apps using the product-governance bundle." \
        "Threshold: $RATE_LIMIT_ERROR_THRESHOLD over the last ${ANALYTICS_WINDOW_MIN}m."$'\n'"$rl_n over threshold:"$'\n'"$rl_list")" '. += [$i]')
fi

issues_json=$(apigee_append_api_error_issue "$issues_json" "the HTTP error rate analysis")
echo "$issues_json" > "$ISSUES_FILE"
echo "HTTP error rate analysis complete. Found $(jq length "$ISSUES_FILE") issue(s)."
