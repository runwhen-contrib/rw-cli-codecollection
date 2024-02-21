#!/bin/bash
# -----------------------------------------------------------------------------
# Script Information and Metadata
# -----------------------------------------------------------------------------
# Author: @stewartshea
# Description: This script is designed to fetch and process Kubernetes logs 
# and provide helpful insights based on the logs. It uses lnav to sift and 
# query the logs for detail, and then tryies to match namespace resources with 
# some of the text created by the queries. This can be extended as needed to 
# cover many logfile use cases
# -----------------------------------------------------------------------------

# Initialize recommendations
recommendations=()

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


# Ensure a deployment name was provided
if [ -z "$DEPLOYMENT_NAME" ]; then
    echo "You must provide a Kubernetes Deployment name."
    exit 1
fi

# Fetch label selectors for the provided deployment
SELECTOR=$(${KUBERNETES_DISTRIBUTION_BINARY} get deployment $DEPLOYMENT_NAME -n ${NAMESPACE} --context=${CONTEXT} -o=jsonpath='{.spec.selector.matchLabels}' | jq -r 'to_entries | .[] | "\(.key)=\(.value)"' | tr '\n' ',' | sed 's/,$//')
if [ -z "$SELECTOR" ]; then
    echo "No label selectors found for Deployment \`$DEPLOYMENT_NAME\`."
    exit 1
fi

# Iterate through the pods based on the selector and fetch logs
LOG_FILES=() 
while read POD; do
    CONTAINERS=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $POD -n ${NAMESPACE} --context=${CONTEXT} -o=jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}')
    for CONTAINER in $CONTAINERS; do
        if [ -n "$LOGS_ERROR_PATTERN" ] && [ -n "$LOGS_EXCLUDE_PATTERN" ]; then
            # Both error and exclusion patterns provided
            LOGS=$(${KUBERNETES_DISTRIBUTION_BINARY} logs $POD -c $CONTAINER --limit-bytes=256000 --since=3h --context=${CONTEXT} -n ${NAMESPACE} | grep -Ei "${LOGS_ERROR_PATTERN}" | grep -Eiv "${LOGS_EXCLUDE_PATTERN}")
        elif [ -n "$LOGS_ERROR_PATTERN" ]; then
            # Only error pattern provided
            LOGS=$(${KUBERNETES_DISTRIBUTION_BINARY} logs $POD -c $CONTAINER --limit-bytes=256000 --since=3h --context=${CONTEXT} -n ${NAMESPACE} | grep -Ei "${LOGS_ERROR_PATTERN}")
        elif [ -n "$LOGS_EXCLUDE_PATTERN" ]; then
            # Only exclusion pattern provided
            LOGS=$(${KUBERNETES_DISTRIBUTION_BINARY} logs $POD -c $CONTAINER --limit-bytes=256000 --since=3h --context=${CONTEXT} -n ${NAMESPACE} | grep -Eiv "${LOGS_EXCLUDE_PATTERN}")
        else
            # Neither pattern provided
            LOGS=$(${KUBERNETES_DISTRIBUTION_BINARY} logs $POD -c $CONTAINER --limit-bytes=256000 --since=3h --context=${CONTEXT} -n ${NAMESPACE})
        fi
        
        # Check log format and store appropriately
        FIRST_LINE=$(echo "$LOGS" | head -n 1)
        EXT=$(echo "$FIRST_LINE" | jq -e . &>/dev/null && echo "json" || echo "txt")
        FILENAME="${POD}_${CONTAINER}_logs.$EXT"
        LOG_FILES+=("$FILENAME")
        echo "Fetching logs for Pod: $POD, Container: $CONTAINER. Saving to $FILENAME."
        echo "$LOGS" > $FILENAME
    done
done < <(${KUBERNETES_DISTRIBUTION_BINARY} get pods --selector=$SELECTOR -n ${NAMESPACE} --context=${CONTEXT} -o=jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

# Initialize an issue description array
issue_descriptions=()

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
echo "---"
echo "Query for HTTP Path patterns"
for FILE in "${LOG_FILES[@]}"; do
    echo "$FILE"
    LOG_SUMMARY=$(lnav -n -c ';SELECT COUNT(*) AS error_count, CASE WHEN "http.req.path" LIKE "/product%" THEN "/product" ELSE "http.req.path" END AS root_path, "http.resp.status" FROM http_logrus_custom WHERE "http.resp.status" = 500 AND NOT "http.req.path" = "/" GROUP BY root_path, "http.resp.status" ORDER BY error_count DESC;' $FILE)
    echo "$LOG_SUMMARY"
    if [[ $LOG_SUMMARY ]]; then 
        INTERESTING_PATHS+=$(echo "$LOG_SUMMARY" | awk 'NR>1 && NR<5 {sub(/^\//, "", $2); print $2}')$'\n'
    fi
done

if [[ -n "$INTERESTING_PATHS" ]]; then
    SEARCH_RESOURCES+=$(echo "$INTERESTING_PATHS" | awk -F'/' '{for (i=1; i<=NF; i++) print $i}' | sort | uniq)
    FORMATTED_RESOURCES=$(echo "$SEARCH_RESOURCES" | sed 's/^/\//' | xargs)
    issue_descriptions+=("HTTP Errors found for paths: $FORMATTED_RESOURCES")
else
    echo "No interesting HTTP paths found."
fi

## Lightweight - we explicitly specify which resources we want to search
# Run RESOURCE_SEARCH_LIST only if SEARCH_RESOURCES has content
if [[ -n "$SEARCH_RESOURCES" ]]; then
    RESOURCE_SEARCH_LIST=$(${KUBERNETES_DISTRIBUTION_BINARY} get deployment,pods,service,statefulset --context=${CONTEXT} -n ${NAMESPACE})
else
    echo "No search queries based on HTTP Paths returned results."
fi


# Search for error fields and strings
echo "---"
echo "Query for generic error logs with lnav and sort"
for FILE in "${LOG_FILES[@]}"; do
    echo "$FILE"
    ERROR_SUMMARY=$(lnav -n -c ';SELECT error, COUNT(*) AS count FROM http_logrus_custom WHERE error IS NOT NULL GROUP BY error;' $FILE)
    echo "$ERROR_SUMMARY"
    ERROR_FUZZY_STRING+=$(echo "$ERROR_SUMMARY" | head -n 3 | tr -d '":' | tr ' ' '\n' | awk '{ for (i=1; i<=NF; i++) if (i != 2) print $i }')
done
ERROR_FUZZY_STRING=$(echo "$ERROR_FUZZY_STRING" | sort | uniq)
##### End query #####

# If neither above work, query with grep
if [[ -z "$ERROR_FUZZY_STRING" && -z "$INTERESTING_PATHS" ]]; then
    # Define patterns to grep for errors
    grep_patterns=(
        "no such host"
        "error"
        "dial tcp: lookup"
        "No space left on device"
    )
    echo "---"
    echo "Fallback search: Grep error logs and sort"
    for FILE in "${LOG_FILES[@]}"; do
        echo "Processing file: $FILE"
        for grep_pattern in "${grep_patterns[@]}"; do
            # Use process substitution to avoid subshell creation by the pipeline
            while IFS= read -r line; do
                # Remove timestamp
                line=$(echo "$line" | sed 's/^[^ ]* //')
                echo "$line"
                if [[ "$line" =~ $grep_pattern ]]; then
                    case $grep_pattern in
                        "no such host")
                            # Extract hostname and perform actions specific to "no such host"
                            host=$(echo "$line" | grep -oP '(?<=http://)[^/]+' | uniq | sed 's/^\s+|\s+$//g' | tr -d "[:space:]")
                            echo "Issue with host: $host"
                            ERROR_FUZZY_STRING+="$host"
                            ;;
                        "error")
                            # Handle general "error" differently if needed
                            ;;
                        "dial tcp: lookup")
                            # Handle "dial tcp: lookup" errors differently if needed
                            ;;
                        "No space left on device")
                            recommendations+=("Fetch the Storage Utilization for PVC Mounts in Namespace \`${NAMESPACE}\`")                    
                            ;;
                    esac
                fi
            done < <(grep "$grep_pattern" "$FILE" | sed 's/^[^ ]* //' | sort | uniq)
        done
    done
    ERROR_FUZZY_STRING=$(echo "$ERROR_FUZZY_STRING" | tr ' ' '\n' | sort | uniq | tr '\n' ' '| tr -d "[:space:]")
    echo "Error summary: $ERROR_FUZZY_STRING"
fi

# Fuzzy match env vars in deployments with ERROR_FUZZY_STRING
declare -a FUZZY_ENV_VAR_RESOURCE_MATCHES
if [[ -n "$ERROR_FUZZY_STRING" ]]; then
    # Filter out common words from ERROR_FUZZY_STRING
    FILTERED_ERROR_STRING=$(filter_common_words "$ERROR_FUZZY_STRING")
    # Convert FILTERED_ERROR_STRING into an array
    mapfile -t PATTERNS <<< "$FILTERED_ERROR_STRING"

    for resource_type in "deployments" "statefulsets"; do
        for pattern in "${PATTERNS[@]}"; do
            while IFS="|" read -r resource_name env_key env_value; do
                formatted_string="$pattern:$resource_type/$resource_name:$env_key:$env_value"
                FUZZY_ENV_VAR_RESOURCE_MATCHES+=("$formatted_string")
            done < <(${KUBERNETES_DISTRIBUTION_BINARY} get "$resource_type" -n "$NAMESPACE" --context=$CONTEXT -o=json | jq --arg pattern "$pattern" -r \
                    ".items[] | 
                    select(
                        .spec.template.spec.containers[]? |
                        .env[]? |
                        select(
                            (.name? // empty | ascii_downcase | contains(\$pattern)) or 
                            (.value? // empty | ascii_downcase | contains(\$pattern))
                        )
                    ) |
                    {resource_name: .metadata.name, matched_env: (.spec.template.spec.containers[] | .env[] | select((.name? // empty | ascii_downcase | contains(\$pattern)) or (.value? // empty | ascii_downcase | contains(\$pattern))))} |
                    [.resource_name, .matched_env.name, .matched_env.value] | join(\"|\")")

        done
    done
else
    echo "No search queries or fuzzy matches to perform."
fi

for match in "${FUZZY_ENV_VAR_RESOURCE_MATCHES[@]}"; do
    IFS=':' read -ra parts <<< "$match"
    string=${parts[0]}
    resource=${parts[1]}
    env_key=${parts[2]}
    env_value=${parts[3]}
    echo "Found string \`$string\` in resource \`$resource\`. Check manifest and environment variable \`$env_key\` for accuracy.  "
done

# Fetch namespace events for searching through
EVENT_SEARCH_LIST=$(${KUBERNETES_DISTRIBUTION_BINARY}  get events --context=${CONTEXT} -n ${NAMESPACE})
event_details="\nThe namespace \`${NAMESPACE}\` has produced the following interesting events:"
event_details+="\n"

# For each value, search the namespace for applicable resources and events
for RESOURCE in "${SEARCH_RESOURCES[@]}"; do 
    event_details+=$(echo "$EVENT_SEARCH_LIST" | grep "$RESOURCE" | grep -Eiv "Normal")
    INTERESTING_RESOURCES+=$(echo "$RESOURCE_SEARCH_LIST" | grep "$RESOURCE")
done


declare -A seen_resources

if [[ ${#FUZZY_ENV_VAR_RESOURCE_MATCHES[@]} -ne 0 ]]; then
    for match in "${FUZZY_ENV_VAR_RESOURCE_MATCHES[@]}"; do        
        IFS=':' read -ra parts <<< "$match"
        string=${parts[0]}
        resource=${parts[1]}
        env_key=${parts[2]}
        env_value=${parts[3]}

        if [[ -z ${seen_resources[$resource]} ]]; then
            issue_descriptions+=("Error log could be related to \`$resource\`")
            recommendations+=("Review manifest for \`$resource\` in namespace: \`${NAMESPACE}\`. Matched error log string \`$string\` in environment variable \`$env_key\`.  ")
            seen_resources[$resource]=1
        fi
    done
fi

if [[ -n "$INTERESTING_RESOURCES" ]]; then
    while read -r line; do
        # Splitting columns into array
        IFS=' ' read -ra cols <<< "$line"
        resource="${cols[0]}"
        status="${cols[1]}"
        restarts="${cols[3]}"

        # Extracting resource type and name
        IFS='/' read -ra details <<< "$resource"
        type="${details[0]}"
        name="${details[1]}"

        case "$type" in
        pod)
            if [[ "$status" != "Running" ]]; then
                recommendations+=("Troubleshoot failed pods in namespace \`${NAMESPACE}\`")
            fi
            if ((restarts > 0)); then
                recommendations+=("Troubleshoot container restarts in namespace \`${NAMESPACE}\`")
            fi
            ;;
        deployment|deployment.apps)
            recommendations+=("Check Deployment health \`$name\` in namespace \`${NAMESPACE}\`")
            ;;
        service)
            recommendations+=("Check Service health \`$name\` in namespace \`${NAMESPACE}\`")
            ;;
        statefulset|statefulset.apps)
            recommendations+=("Check Statefulset health \`$name\` in namespace \`${NAMESPACE}\`")
            ;;
        esac
    done <<< "$INTERESTING_RESOURCES"
fi 

# Display the issue descriptions
if [[ ${#issue_descriptions[@]} -ne 0 ]]; then
    printf "\nIssues Identified: \n"
    printf "%s\n" "${issue_descriptions[@]}" | sort -u
fi 

# Display the interesting events for report details
if [[ -n "$event_details" ]]; then
    echo -e "$event_details"
fi

# Display all unique recommendations that can be shown as Next Steps
if [[ ${#recommendations[@]} -ne 0 ]]; then
    printf "\nRecommended Next Steps: \n"
    printf "%s\n" "${recommendations[@]}" | sort -u
fi