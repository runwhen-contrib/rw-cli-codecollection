#!/bin/bash
set -eo pipefail

# -----------------------------------------------------------------------------
# Script Information and Metadata
# -----------------------------------------------------------------------------
# Author: @stewartshea
# Description: This script takes in event message strings captured from a 
# Kubernetes based system and provides some generalized next steps based on the 
# content and frequency of the message. 
# -----------------------------------------------------------------------------

#!/bin/bash

# Input: List of event messages, related owner kind, and related owner name
event_messages="$1"
owner_kind="$2"  
owner_name="$3"

# Process the log messages
echo "$event_messages" | awk -F';' -v owner_kind="$owner_kind" -v owner_name="$owner_name" '
function extract_common_pattern(str1, str2,  common_pattern) {
    # Function to extract common pattern from two strings
    len1 = length(str1)
    len2 = length(str2)
    max_length = 0
    for (i = 1; i <= len1; i++) {
        for (j = 1; j <= len2; j++) {
            if (substr(str1, i, 1) == substr(str2, j, 1)) {
                l = 0
                while (substr(str1, i + l, 1) == substr(str2, j + l, 1) && i + l <= len1 && j + l <= len2)
                    l++
                if (l > max_length) {
                    max_length = l
                    common_pattern = substr(str1, i, l)
                }
            }
        }
    }
    return common_pattern
}

{
    delete count
    pattern_found = 0
    for (i = 1; i <= NF; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)  # Trim whitespace
        for (j = i + 1; j <= NF; j++) {
            pattern = extract_common_pattern($i, $j, "")
            if (length(pattern) > 10) {
                count[pattern]++
            }
        }
    }

    for (pattern in count) {
        total_count = 0
        for (i = 1; i <= NF; i++) {
            if (index($i, pattern) != 0) {
                total_count++
            }
        }
        count[pattern] = total_count

        if (total_count > 1) {
            # print "Pattern:", pattern, ", Count:", total_count
            # Custom logic for matching patterns and defining next steps
            # Partial match example
            if (owner_kind == "Deployment" && index(pattern, "Created pod: ") != 0) {
                print "Troubleshoot Deployment Replicas for `"owner_name"`"
                print "Check Deployment Event Anomalies for `"owner_name"`"
            }

            pattern_found = 1
        }
    }

    if (pattern_found == 0) {
        print "No repeating log messages found that would require investigation."
    }
}'