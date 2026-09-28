#!/usr/bin/env bash
set -euo pipefail
set -x
# Lightweight SLI health probe: scores 1 when no severity-3+ reclamation signals exist.
# Uses limited pagination (SLI_MAX_PAGES) to stay under 30 seconds.

: "${ATLASSIAN_ORG_ID:?Must set ATLASSIAN_ORG_ID}"
: "${ATLASSIAN_ORG_NAME:?Must set ATLASSIAN_ORG_NAME}"
: "${INACTIVE_DAYS_THRESHOLD:=90}"
: "${PENDING_INVITE_DAYS_THRESHOLD:=30}"
: "${MIN_OVERLAP_PRODUCTS:=2}"
: "${RECLAMATION_MIN_SEATS:=5}"
: "${SLI_MAX_PAGES:=2}"

source "$(dirname "$0")/atlassian-api-helpers.sh"

export ATLASSIAN_MAX_PAGES="${SLI_MAX_PAGES}"
rm -f "$INVENTORY_CACHE_FILE" "$DIRECTORY_USERS_CACHE_FILE" 2>/dev/null || true

inactive_count=0
overlap_count=0
stale_invites=0
api_ok=1

if ensure_user_inventory; then
  inactive_count=$(jq \
    --argjson threshold "$INACTIVE_DAYS_THRESHOLD" \
    'def days_since_iso($iso):
       if ($iso // "") == "" then 999999
       else (($iso | sub("\\.[0-9]+"; "") | fromdateiso8601?) as $ts |
         if $ts == null then 999999 else (((now - $ts) / 86400) | floor) end) end;
     [.users[] | select(.access_billable == true) |
      (.product_access // []) as $pa |
      if ($pa | length) == 0 then true
      else all($pa[]; days_since_iso(.last_active) >= $threshold) end
    ] | length' "$INVENTORY_CACHE_FILE")

  overlap_count=$(jq \
    --argjson threshold "$INACTIVE_DAYS_THRESHOLD" \
    --argjson min_products "$MIN_OVERLAP_PRODUCTS" \
    'def days_since_iso($iso):
       if ($iso // "") == "" then 999999
       else (($iso | sub("\\.[0-9]+"; "") | fromdateiso8601?) as $ts |
         if $ts == null then 999999 else (((now - $ts) / 86400) | floor) end) end;
     [.users[] | select(.access_billable == true) |
      (.product_access // []) as $pa | select(($pa | length) >= $min_products) |
      ($pa | map(days_since_iso(.last_active) < $threshold)) as $active |
      ($pa | length) > ($active | map(select(.)) | length)
    ] | length' "$INVENTORY_CACHE_FILE")
else
  api_ok=0
fi

if ensure_directory_users; then
  stale_invites=$(jq \
    --argjson threshold "$PENDING_INVITE_DAYS_THRESHOLD" \
    'def days_since_iso($iso):
       if ($iso // "") == "" then 999999
       else (($iso | sub("\\.[0-9]+"; "") | fromdateiso8601?) as $ts |
         if $ts == null then 999999 else (((now - $ts) / 86400) | floor) end) end;
     [.users[] |
      select(
        (.membershipStatus // "" | ascii_downcase | test("pending")) or
        (.accountStatus // "" | ascii_downcase | test("pending"))
      ) |
      days_since_iso(.addedToOrg // .added_to_org // "") >= $threshold
    ] | length' "$DIRECTORY_USERS_CACHE_FILE")
else
  api_ok=0
fi

severity3_plus=0
[[ "$inactive_count" -ge "$RECLAMATION_MIN_SEATS" ]] && severity3_plus=1
[[ "$overlap_count" -ge "$RECLAMATION_MIN_SEATS" ]] && severity3_plus=1
[[ "$stale_invites" -ge 1 ]] && severity3_plus=1

inactive_score=1
overlap_score=1
invite_score=1
api_score=1

[[ "$inactive_count" -ge "$RECLAMATION_MIN_SEATS" ]] && inactive_score=0
[[ "$overlap_count" -ge "$RECLAMATION_MIN_SEATS" ]] && overlap_score=0
[[ "$stale_invites" -ge 1 ]] && invite_score=0
[[ "$api_ok" -eq 0 ]] && api_score=0

health_score=$(awk -v a="$inactive_score" -v b="$overlap_score" -v c="$invite_score" -v d="$api_score" \
  'BEGIN { printf "%.2f", (a+b+c+d)/4 }')

jq -n \
  --argjson health_score "$health_score" \
  --argjson inactive_score "$inactive_score" \
  --argjson overlap_score "$overlap_score" \
  --argjson invite_score "$invite_score" \
  --argjson api_score "$api_score" \
  --argjson inactive_count "$inactive_count" \
  --argjson overlap_count "$overlap_count" \
  --argjson stale_invites "$stale_invites" \
  --argjson severity3_plus "$severity3_plus" \
  '{
    health_score: ($health_score | tonumber),
    sub_scores: {
      inactive_billable: $inactive_score,
      product_overlap: $overlap_score,
      stale_invites: $invite_score,
      api_reachability: $api_score
    },
    counts: {
      inactive_billable: $inactive_count,
      overlap_candidates: $overlap_count,
      stale_invites: $stale_invites,
      severity3_plus_signals: $severity3_plus
    }
  }'
