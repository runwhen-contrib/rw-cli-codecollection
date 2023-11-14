#!/bin/bash

# -----------------------------------------------------------------------------
# Script Information and Metadata
# -----------------------------------------------------------------------------
# Author: @stewartshea
# Description: This script is designed to take a pass at ingesting log data 
# into lnav and querying it (using SQL). 
# -----------------------------------------------------------------------------
LOG_FILES=("$@")

# Update PATH to ensure script dependencies are found
export PATH="$PATH:$HOME/.lnav:$HOME/.local/bin"

# -------------------------- Function Definitions -----------------------------

# Check if a command exists
function check_command_exists() {
    if ! command -v $1 &> /dev/null; then
        echo "$1 could not be found"
        exit
    fi
}

# Function to filter out common words
filter_common_words() {
    local input_string="$1"
    local common_words=" to on add could desc not lookup "
    local filtered_string=""
    
    # Loop through each word in the input string
    while IFS= read -r word; do
        # If the word is not in the common words list, add to filtered string
        if [[ ! " $common_words " =~ " $word " ]] && [[ ! "$word" =~ ^[0-9]+$ ]]; then
            filtered_string+="$word"$'\n'
        fi
    done <<< "$input_string"
    
    echo "$filtered_string"
}
# ------------------------- Dependency Verification ---------------------------

# Ensure all the required binaries are accessible
check_command_exists ${KUBERNETES_DISTRIBUTION_BINARY}
check_command_exists jq
check_command_exists lnav

# Load custom formats for lnav if it's installed
# FIXME: This could be done more efficiently
# Search for the formats directory
lnav_formats_path=$(find / -type d -path '*/extras/lnav/formats' -print -quit 2>/dev/null)
cp -rf $lnav_formats_path/* $HOME/.lnav/formats/installed

# ------------------------------- lnav queries --------------------------------
# The gist here is to provide various types of lnav queries. If a query has
# results, then we can perform some additional tasks that suggest resources
# which might be related
#-------------------------------------------------------------------------------


# NOTE: Work needs to be done here to scale this - as we have hard coded in the 
# fields and the format - need to figure out how to best match the right formats, 
# or can we just use logline

SEARCH_RESOURCES=""
##### Begin query #####

# Format file / table http_logrus_custom
# Search for http log format used by online-boutique (which uses logrus but is custom)
for FILE in "${LOG_FILES[@]}"; do
    echo "$FILE"
    LOG_SUMMARY=$(lnav -n -c ';SELECT COUNT(*) AS error_count, CASE WHEN "http.req.path" LIKE "/product%" THEN "/product" ELSE "http.req.path" END AS root_path, "http.resp.status" FROM http_logrus_custom WHERE "http.resp.status" = 500 AND NOT "http.req.path" = "/" GROUP BY root_path, "http.resp.status" ORDER BY error_count DESC;' $FILE)
    echo "$LOG_SUMMARY"
    INTERESTING_PATHS+=$(echo "$LOG_SUMMARY" | awk 'NR>1 && NR<5 {sub(/^\//, "", $2); print $2}')$'\n'
done

if [[ -n "$INTERESTING_PATHS" ]]; then
    SEARCH_RESOURCES+=$(echo "$INTERESTING_PATHS" | awk -F'/' '{for (i=1; i<=NF; i++) print $i}' | sort | uniq)
    issue_descriptions+=("HTTP Errors found for paths: $SEARCH_RESOURCES")
else
    echo "No interesting HTTP paths found."
fi

# Search for error fields and strings
for FILE in "${LOG_FILES[@]}"; do
    echo "$FILE"
    ERROR_SUMMARY=$(lnav -n -c ';SELECT error, COUNT(*) AS count FROM http_logrus_custom WHERE error IS NOT NULL GROUP BY error;' $FILE)
    echo "$ERROR_SUMMARY"
    ERROR_FUZZY_STRING+=$(echo "$ERROR_SUMMARY" | head -n 3 | tr -d '":' | tr ' ' '\n' | awk '{ for (i=1; i<=NF; i++) if (i != 2) print $i }')
done
ERROR_FUZZY_STRING=$(echo "$ERROR_FUZZY_STRING" | sort | uniq)
##### End query #####


echo "HELLO"