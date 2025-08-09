#!/bin/bash

REGISTRY_NAME=${ACR_NAME:-}
ISSUES_FILE="dns_tls_issues.json"
echo '[]' > "$ISSUES_FILE"

add_issue() {
  local title="$1"
  local severity="$2"
  local expected="$3"
  local actual="$4"
  local details="$5"
  local next_steps="$6"
  details=$(echo "$details" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
  next_steps=$(echo "$next_steps" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
  local issue="{\"title\":\"$title\",\"severity\":$severity,\"expected\":\"$expected\",\"actual\":\"$actual\",\"details\":\"$details\",\"next_steps\":\"$next_steps\"}"
  jq ". += [${issue}]" "$ISSUES_FILE" > temp.json && mv temp.json "$ISSUES_FILE"
}

# DNS check
nslookup $REGISTRY_NAME.azurecr.io > /dev/null 2>&1
if [ $? -ne 0 ]; then
  add_issue "DNS Lookup failed" 4 "DNS should resolve" "Failed to resolve registry DNS" "Check network/DNS settings"
fi

# TLS check
openssl s_client -connect $REGISTRY_NAME.azurecr.io:443 -servername $REGISTRY_NAME.azurecr.io < /dev/null > tls_log.txt 2>&1
if grep -q "Verify return code: 0 (ok)" tls_log.txt; then
  echo "TLS handshake success"
else
  add_issue "TLS handshake failed" 4 "TLS handshake should succeed" "Failed handshake or cert issue" "Check firewall and trust chains"
fi
rm -f tls_log.txt
