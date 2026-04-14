#!/usr/bin/env bash
# SLI dimension: SPF TXT includes mailgun (1/0 JSON).
set -euo pipefail
set -x

: "${MAILGUN_SENDING_DOMAIN:?}"

txt=$(dig +short TXT "${MAILGUN_SENDING_DOMAIN}" | tr -d '"' | tr '\n' ' ')
score=0
if echo "$txt" | grep -qi 'v=spf1' && echo "$txt" | grep -qi 'mailgun'; then
  score=1
fi

jq -n --argjson s "$score" '{score: $s}'
