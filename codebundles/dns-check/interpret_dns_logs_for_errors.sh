#!/bin/bash

# Variables
LOG_FILE="/var/log/syslog"
ERROR_KEYWORD="error"
DNS_KEYWORD="named"

# Check if the log file exists
if [ ! -f "$LOG_FILE" ]; then
    echo "Log file not found: $LOG_FILE"
    exit 1
fi

# Search the log file for DNS errors
grep -i "$DNS_KEYWORD" "$LOG_FILE" | grep -i "$ERROR_KEYWORD" > dns_errors.log

# Check if any errors were found
if [ -s dns_errors.log ]; then
    echo "DNS errors found:"
    cat dns_errors.log
else
    echo "No DNS errors found in the log file."
fi

# Clean up
rm dns_errors.log
