#!/bin/bash

# Variables
DOMAIN="runwhen.com"

# Check DNS Configuration for Runwhen.com
echo "Checking DNS Configuration for $DOMAIN"

# Check A Record
echo "Checking A Record:"
dig A $DOMAIN +short

# Check AAAA Record
echo "Checking AAAA Record:"
dig AAAA $DOMAIN +short

# Check CNAME Record
echo "Checking CNAME Record:"
dig CNAME $DOMAIN +short

# Check MX Record
echo "Checking MX Record:"
dig MX $DOMAIN +short

# Check NS Record
echo "Checking NS Record:"
dig NS $DOMAIN +short

# Check PTR Record
echo "Checking PTR Record:"
dig -x $DOMAIN +short

# Check SOA Record
echo "Checking SOA Record:"
dig SOA $DOMAIN +short

# Check SRV Record
echo "Checking SRV Record:"
dig SRV $DOMAIN +short

# Check TXT Record
echo "Checking TXT Record:"
dig TXT $DOMAIN +short

# Check DNSSEC
echo "Checking DNSSEC:"
dig DNSKEY $DOMAIN +short
dig DS $DOMAIN +short

# Check connectivity to DNS Server
echo "Checking connectivity to DNS Server:"
for server in $(dig NS $DOMAIN +short); do
    echo "Pinging $server"
    ping -c 1 $server
done

# Check if domain is resolvable
echo "Checking if domain is resolvable:"
if nslookup $DOMAIN; then
    echo "$DOMAIN is resolvable"
else
    echo "$DOMAIN is not resolvable"
fi

# Check DNS Health
echo "Checking DNS Health:"
dig $DOMAIN +trace
