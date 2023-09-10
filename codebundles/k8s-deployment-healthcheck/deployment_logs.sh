#!/bin/bash

# Add script requirements
# Need to get this passed through from runtime
export PATH="$PATH:$HOME/.lnav:$HOME/.local/bin"

# Ensure ${KUBERNETES_DISTRIBUTION_BINARY} is installed and accessible
if ! command -v ${KUBERNETES_DISTRIBUTION_BINARY} &> /dev/null; then
    echo "${KUBERNETES_DISTRIBUTION_BINARY} could not be found"
    exit
fi

# Ensure jq is installed and accessible
if ! command -v jq &> /dev/null; then
    echo "jq could not be found"
    exit
fi

# Ensure lnav is installed and accessible
if ! command -v lnav &> /dev/null; then
    echo "lnav could not be found"
    exit
else
    # Load custom formats for lnav
    cp -rf ../../../extras/lnav/formats/* $HOME/.config/lnav/formats/installed/
fi


# Ensure a deployment name was provided
if [ -z "$DEPLOYMENT_NAME" ]; then
    echo "You must provide a Kubernetes Deployment name."
    exit 1
fi

SELECTOR=$(${KUBERNETES_DISTRIBUTION_BINARY} get deployment $DEPLOYMENT_NAME --namespace=$NAMESPACE -o=jsonpath='{.spec.selector.matchLabels}' | jq -r 'to_entries | .[] | "\(.key)=\(.value)"' | tr '\n' ',' | sed 's/,$//')

if [ -z "$SELECTOR" ]; then
    echo "No label selectors found for Deployment $DEPLOYMENT_NAME."
    exit 1
fi

while read POD; do
    CONTAINERS=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $POD --namespace=$NAMESPACE -o=jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}')
    for CONTAINER in $CONTAINERS; do
        if [ -n "$LOGS_ERROR_PATTERN" ] && [ -n "$LOGS_EXCLUDE_PATTERN" ]; then
            # Both error and exclusion patterns provided
            LOGS=$(${KUBERNETES_DISTRIBUTION_BINARY} logs $POD -c $CONTAINER --namespace=$NAMESPACE  --limit-bytes=256000 --since=3h --context=${CONTEXT} -n ${NAMESPACE} | grep -Ei "${LOGS_ERROR_PATTERN}" | grep -Eiv "${LOGS_EXCLUDE_PATTERN}")
        elif [ -n "$LOGS_ERROR_PATTERN" ]; then
            # Only error pattern provided
            LOGS=$(${KUBERNETES_DISTRIBUTION_BINARY} logs $POD -c $CONTAINER --namespace=$NAMESPACE  --limit-bytes=256000 --since=3h --context=${CONTEXT} -n ${NAMESPACE} | grep -Ei "${LOGS_ERROR_PATTERN}")
        elif [ -n "$LOGS_EXCLUDE_PATTERN" ]; then
            # Only exclusion pattern provided
            LOGS=$(${KUBERNETES_DISTRIBUTION_BINARY} logs $POD -c $CONTAINER --namespace=$NAMESPACE  --limit-bytes=256000 --since=3h --context=${CONTEXT} -n ${NAMESPACE} | grep -Eiv "${LOGS_EXCLUDE_PATTERN}")
        else
            # Neither pattern provided
            LOGS=$(${KUBERNETES_DISTRIBUTION_BINARY} logs $POD -c $CONTAINER --namespace=$NAMESPACE  --limit-bytes=256000 --since=3h --context=${CONTEXT} -n ${NAMESPACE})
        fi
        
        # Check if the first line of logs is in JSON format
        FIRST_LINE=$(echo "$LOGS" | head -n 1)
        if echo "$FIRST_LINE" | jq -e . &>/dev/null; then
            EXT="json"
        else
            EXT="txt"
        fi
        
        # Output to a file
        FILENAME="${POD}_${CONTAINER}_logs.$EXT"
        # Add file name to array
        LOG_FILES+=("$FILENAME")
        echo "Fetching logs for Pod: $POD, Container: $CONTAINER. Saving to $FILENAME."
        echo "$LOGS" > $FILENAME
    done
done < <(${KUBERNETES_DISTRIBUTION_BINARY} get pods --selector=$SELECTOR --namespace=$NAMESPACE -o=jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

# Loop through each file and look for 
# Work needs to be done here to scale this - as we have hard coded in the fields and the format - need to figure out how to best match the right formats, or can we just use logline
for FILE in "${LOG_FILES[@]}"; do
    echo "$FILE"
    # LOG_SUMMARY=$(lnav -n -c ';SELECT COUNT(*) AS error_count, CASE WHEN "http.req.path" LIKE "/product%" THEN "/product" ELSE "http.req.path" END AS root_path, "http.resp.status" FROM http_logrus_custom WHERE "http.resp.status" = 500 AND NOT "http.req.path" = "/" GROUP BY root_path, "http.resp.status" ORDER BY error_count DESC;' $FILE)
    LOG_SUMMARY=$(lnav -n -c ';SELECT COUNT(*) AS error_count, CASE WHEN "http.req.path" LIKE "/product%" THEN "/product" ELSE "http.req.path" END AS root_path, "http.resp.status" FROM logline WHERE "http.resp.status" = 500 AND NOT "http.req.path" = "/" GROUP BY root_path, "http.resp.status" ORDER BY error_count DESC;' $FILE)
    echo "$LOG_SUMMARY"
    INTERESTING_PATHS+=$(echo "$LOG_SUMMARY" | awk 'NR>1 && NR<5 {sub(/^\//, "", $2); print $2}')$'\n'
done

# Split out multiple paths and emove duplicate terms
SEARCH_RESOURCES=$(echo "$INTERESTING_PATHS" | awk -F'/' '{for (i=1; i<=NF; i++) print $i}' | sort | uniq)

# # Fetch a list of all resources in the namespace
## Heavyweight - this times out after 30s, but is a better way to get any and all resources
# SEARCH_LIST=$(${KUBERNETES_DISTRIBUTION_BINARY} api-resources --verbs=list --namespaced -o name  | xargs -n 1 ${KUBERNETES_DISTRIBUTION_BINARY} get --show-kind --ignore-not-found -n $NAMESPACE)

## Lightweight - we explicitly specify which resources we want to interrogate
RESOURCE_SEARCH_LIST=$(${KUBERNETES_DISTRIBUTION_BINARY}  get deployment,pods,service,statefulset --context=${CONTEXT} -n ${NAMESPACE})
EVENT_SEARCH_LIST=$(${KUBERNETES_DISTRIBUTION_BINARY}  get events --context=${CONTEXT} -n ${NAMESPACE})

event_details="The namespace ${NAMESPACE} has produced the following interesting events:"
event_details+="\n"

# For each value, search the namespace for applicable resources
INTERESTING_RESOURCES=""
for RESOURCE in "${SEARCH_RESOURCES[@]}"; do 
    event_details+=$(echo "$EVENT_SEARCH_LIST" | grep "$RESOURCE" | grep -Eiv "Normal")
    INTERESTING_RESOURCES+=$(echo "$RESOURCE_SEARCH_LIST" | grep "$RESOURCE")
done

recommendations=()
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
            recommendations+=("Troubleshoot failed pods in namespace ${NAMESPACE}")
        fi
        if ((restarts > 0)); then
            recommendations+=("Troubleshoot container restarts in namespace ${NAMESPACE}")
        fi
        ;;
    deployment)
        recommendations+=("Check deployment health $name in namespace ${NAMESPACE}")
        ;;
    service)
        recommendations+=("Check service health $name in namespace ${NAMESPACE}")
        ;;
    statefulset)
        recommendations+=("Check statefulSet health $name in namespace ${NAMESPACE}")
        ;;
    esac
done <<< "$INTERESTING_RESOURCES"

echo -e "$event_details"

if [[ ${#recommendations[@]} -ne 0 ]]; then
    printf "Recommended Next Steps: \n"
    printf "%s\n" "${recommendations[@]}" | sort -u
fi