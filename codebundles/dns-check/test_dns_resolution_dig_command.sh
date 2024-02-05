#!/bin/bash

# Variables
DOMAIN_NAME="example.com"
DNS_SERVER="8.8.8.8"

# Test DNS resolution using dig command
echo "Testing DNS resolution for $DOMAIN_NAME using DNS server $DNS_SERVER"
dig @$DNS_SERVER $DOMAIN_NAME

# Check if the DNS resolution was successful
if [[ $? -eq 0 ]]; then
    echo "DNS resolution successful."
else
    echo "DNS resolution failed."
    exit 1
fi

# Extract the A record from the dig command output
A_RECORD=$(dig +short $DOMAIN_NAME)

# Check if the A record was found
if [[ -z $A_RECORD ]]; then
    echo "No A record found for $DOMAIN_NAME."
    exit 1
else
    echo "A record for $DOMAIN_NAME is $A_RECORD"
fi
