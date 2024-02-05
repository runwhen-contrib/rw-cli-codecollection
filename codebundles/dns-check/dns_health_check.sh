#!/bin/bash

# Variables
DNS_SERVER="8.8.8.8"
DOMAIN_TO_CHECK="google.com"
DNS_RECORD_TYPES=("A" "AAAA" "CNAME" "MX" "NS" "PTR" "SOA" "SRV" "TXT")

# Check if dig command is available
if ! command -v dig &> /dev/null
then
    echo "dig command could not be found. Please install dnsutils package."
    exit
fi

# Perform DNS Health Checks
for record in "${DNS_RECORD_TYPES[@]}"
do
    echo "Checking $record record for $DOMAIN_TO_CHECK on DNS server $DNS_SERVER"
    dig @$DNS_SERVER $DOMAIN_TO_CHECK $record +short
done

# Check for DNSSEC
echo "Checking DNSSEC for $DOMAIN_TO_CHECK on DNS server $DNS_SERVER"
dig @$DNS_SERVER $DOMAIN_TO_CHECK DNSKEY +short

# Check DNS response time
echo "Checking DNS response time for $DOMAIN_TO_CHECK on DNS server $DNS_SERVER"
dig @$DNS_SERVER $DOMAIN_TO_CHECK +stats | grep "Query time"

# Check reverse DNS
IP_ADDRESS=$(dig +short $DOMAIN_TO_CHECK)
echo "Checking reverse DNS for IP $IP_ADDRESS on DNS server $DNS_SERVER"
dig @$DNS_SERVER -x $IP_ADDRESS +short
