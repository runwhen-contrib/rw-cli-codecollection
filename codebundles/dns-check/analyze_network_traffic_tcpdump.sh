#!/bin/bash

# Variables
TCPDUMP_PATH="/usr/sbin/tcpdump"
OUTPUT_FILE="/tmp/tcpdump_output.txt"
INTERFACE="eth0"
PORT="53"
PACKET_COUNT="1000"

# Check if tcpdump is installed
if [ ! -f "$TCPDUMP_PATH" ]; then
    echo "Tcpdump not found. Please install tcpdump."
    exit 1
fi

# Start tcpdump to capture DNS traffic
sudo $TCPDUMP_PATH -i $INTERFACE port $PORT -nn -s0 -c $PACKET_COUNT -w $OUTPUT_FILE

# Analyze the output
echo "Analyzing the tcpdump output..."
DNS_QUERIES=$(grep -o 'A\?' $OUTPUT_FILE | wc -l)
DNS_RESPONSES=$(grep -o 'A ' $OUTPUT_FILE | wc -l)

echo "Number of DNS queries: $DNS_QUERIES"
echo "Number of DNS responses: $DNS_RESPONSES"

# Check if there are any DNS errors
DNS_ERRORS=$(grep 'SERVFAIL' $OUTPUT_FILE | wc -l)
if [ $DNS_ERRORS -gt 0 ]; then
    echo "WARNING: Found $DNS_ERRORS DNS errors in the tcpdump output."
fi

# Clean up
rm $OUTPUT_FILE
