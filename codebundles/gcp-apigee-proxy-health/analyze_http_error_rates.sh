#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# analyze_http_error_rates.sh
# Queries Analytics metrics by response_status_code for 401/403/429 rates.
# Flags 401/403 rate elevated (token validation failure, API product mismatch,
# expired developer app credentials) and 429 rate elevated beyond the intended
# quota / spike-arrest policy (rejecting legitimate traffic).
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
. "$(dirname "${BASH_SOURCE[0]}")/apigee_common.sh"

ISSUES_FILE="http_error_rate_issues.json"
issues_json='[]'

if [ -z "$(apigee_access_token)" ]; then
    echo "$issues_json" > "$ISSUES_FILE"
    echo "No access token; skipping HTTP error rate analysis."
    exit 0
fi

ORG="$(apigee_org)"
[ -z "$ORG" ] && { echo "$issues_json" > "$ISSUES_FILE"; echo "Could not resolve org; skipping."; exit 0; }

now_epoch=$(date +%s)
start_epoch=$(( now_epoch - (ANALYTICS_WINDOW_MIN * 60) ))
t_start=$(date -u -d "@$start_epoch" "+%m/%d/%Y %H:%M")
t_end=$(date -u -d "@$now_epoch" "+%m/%d/%Y %H:%M")

echo "Analyzing HTTP error rates for org: $ORG (window: ${ANALYTICS_WINDOW_MIN}m, 401/403>${AUTH_ERROR_RATE_THRESHOLD}, 429>${RATE_LIMIT_ERROR_THRESHOLD})"

# Dimension is the composite apiproxy,response_status_code; select message_count.
resp_all=""
for env in $(apigee_list_environments "$ORG" | jq -r '.[]'); do
    echo "  Querying HTTP error rates for environment '$env'..."
    resp=$(apigee_stats "$ORG" "$env" "apiproxy,response_status_code" "sum(message_count)" "$t_start" "$t_end")
    resp_all="$resp_all
$resp"

    # Each dimension has name "<proxy>,<statusCode>".
    echo "$resp" | jq -c '.environments[0].dimensions // []' | jq -c --arg f "$(apigee_expand_csv "$PROXIES")" '
        .[] |
        select(.name | contains(",")) |
        if $f == "All" then .
        else select(.name | split(",")[0] as $n | ($f | split(",")) | index($n))
        end' | while read -r dim; do
            raw=$(echo "$dim" | jq -r '.name')
            proxy=$(echo "$raw" | cut -d, -f1)
            code=$(echo "$raw" | cut -d, -f2)
            count=$(echo "$dim" | jq -r '[.metrics[] | select(.name|contains("message_count")) | .values[0]] | .[0] // "0"' | awk '{printf "%.0f", $1}')
            # Aggregate per (proxy,code) across environments: keep running in a temp file keyed by proxy|code
            key="$proxy|$code"
            echo "$key $count" >> /tmp/apigee_http_rates.$$.tmp
        done
done

if [ ! -f /tmp/apigee_http_rates.$$.tmp ]; then
    echo "No HTTP error rate data returned in the lookback window."
    echo "$issues_json" > "$ISSUES_FILE"
    exit 0
fi

# Aggregate totals per proxy (after aggregating per proxy+code, then per proxy).
total_per_proxy=$(awk '{ split($1,k,"|"); sum[k[1]] += $2 } END { for (p in sum) print p, sum[p] }' /tmp/apigee_http_rates.$$.tmp)
code_sum=$(awk '{ split($1,k,"|"); sum[k[1]"|"k[2]] += $2 } END { for (pk in sum) print pk, sum[pk] }' /tmp/apigee_http_rates.$$.tmp)

# Map code -> total per proxy
declare -A proxy_total
while read -r p t; do proxy_total["$p"]="$t"; done <<< "$total_per_proxy"
declare -A code_total
while read -r pk c; do code_total["$pk"]="$c"; done <<< "$code_sum"

for pk in "${!code_total[@]}"; do
    proxy="${pk%%|*}"
    code="${pk##*|}"
    total="${proxy_total[$proxy]:-0}"
    count="${code_total[$pk]}"
    [ "$total" = "0" ] && continue
    rate=$(awk -v c="$count" -v t="$total" 'BEGIN { printf "%.6f", c/t }')

    case "$code" in
        401|403)
            if [ "$(awk -v r="$rate" -v thr="$AUTH_ERROR_RATE_THRESHOLD" 'BEGIN { print (r > thr) ? 1 : 0 }')" = "1" ]; then
                issue=$(jq -n \
                    --arg title "Elevated HTTP $code rate for proxy \`$proxy\`" \
                    --arg details "Proxy '$proxy' returned $count HTTP $code responses out of $total requests (rate $rate), exceeding AUTH_ERROR_RATE_THRESHOLD $AUTH_ERROR_RATE_THRESHOLD. $code indicates token validation failure / API product mismatch / expired developer app credentials." \
                    --arg severity "3" \
                    --arg expected "401/403 rate should remain below $AUTH_ERROR_RATE_THRESHOLD" \
                    --arg actual "Proxy '$proxy' HTTP $code rate is $rate" \
                    --arg next_steps "Diagnose with the gcp-apigee-product-governance bundle: check API product / developer app / credential expiry and OAuth / verify-api-key policy configuration for '$proxy'." \
                    '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
                issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
                echo "$issues_json" > "$ISSUES_FILE"
            fi
            ;;
        429)
            if [ "$(awk -v r="$rate" -v thr="$RATE_LIMIT_ERROR_THRESHOLD" 'BEGIN { print (r > thr) ? 1 : 0 }')" = "1" ]; then
                issue=$(jq -n \
                    --arg title "Elevated HTTP 429 rate for proxy \`$proxy\`" \
                    --arg details "Proxy '$proxy' returned $count HTTP 429 responses out of $total requests (rate $rate), exceeding RATE_LIMIT_ERROR_THRESHOLD $RATE_LIMIT_ERROR_THRESHOLD. The quota / spike-arrest policy may be rejecting legitimate traffic, or clients are over the intended limit." \
                    --arg severity "3" \
                    --arg expected "429 rate should remain below $RATE_LIMIT_ERROR_THRESHOLD" \
                    --arg actual "Proxy '$proxy' HTTP 429 rate is $rate" \
                    --arg next_steps "Review the Quota and SpikeArrest policies for '$proxy' and confirm the configured limits match the intended capacity. If limits are correct, investigate unexpected burst traffic on the API product / developer apps using the product-governance bundle." \
                    '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
                issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
                echo "$issues_json" > "$ISSUES_FILE"
            fi
            ;;
    esac
done

rm -f /tmp/apigee_http_rates.$$.tmp

if [ ! -s "$ISSUES_FILE" ]; then
    echo "[]" > "$ISSUES_FILE"
fi

echo "HTTP error rate analysis complete. Found $(jq length "$ISSUES_FILE") issue(s)."
