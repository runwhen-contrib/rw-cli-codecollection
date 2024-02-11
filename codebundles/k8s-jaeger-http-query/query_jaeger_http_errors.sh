#!/bin/bash

# Define an array of label selectors to identify the Jaeger Query service
LABEL_SELECTORS=("app=jaeger,app.kubernetes.io/component=query" "app=jaeger-query")

# Initialize an empty array to hold the names of Jaeger services
JAEGER_SERVICES=()

# Iterate through the label selectors to find Jaeger Query services
for label in "${LABEL_SELECTORS[@]}"; do
    readarray -t services < <(${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} get svc -n ${NAMESPACE} -l ${label} -o jsonpath='{.items[*].metadata.name}')
    # If services are found with the current label selector, add them to the JAEGER_SERVICES array
    if [ ${#services[@]} -gt 0 ]; then
        JAEGER_SERVICES+=("${services[@]}")
    fi
done

# Verify that at least one Jaeger Query service was found
if [ ${#JAEGER_SERVICES[@]} -eq 0 ]; then
    echo "Jaeger Query service not found in namespace ${NAMESPACE}"
    exit 1
fi

# Use the first found service for demonstration purposes
JAEGER_SERVICE_NAME=${JAEGER_SERVICES[0]}
echo "--------"
echo "Jaeger Service Found: $JAEGER_SERVICE_NAME"
echo "--------"

# Fetch all ports for the service
ports=$(${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} get svc ${JAEGER_SERVICE_NAME} -n ${NAMESPACE} -o jsonpath='{.spec.ports[*].name}')

# Convert string to array
IFS=' ' read -r -a port_names <<< "$ports"

# Initialize JAEGER_PORT to an empty value
JAEGER_PORT=""

# Loop through all port names and check for your conditions
for port_name in "${port_names[@]}"; do
    if [[ "$port_name" == "query" || "$port_name" == "http-query" || "$port_name" == "query-http" ]]; then
        # If a matching port name is found, fetch its port number
        JAEGER_PORT=$(${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} get svc ${JAEGER_SERVICE_NAME} -n ${NAMESPACE} -o jsonpath="{.spec.ports[?(@.name==\"$port_name\")].port}")
        break # Assuming only one matching port is needed
    fi
done

if [ -z "$JAEGER_PORT" ]; then
    echo "Jaeger Query API port not found for service ${JAEGER_SERVICE_NAME}"
    exit 1
fi

echo "Found Jaeger Query API port: $JAEGER_PORT"

if [ -z "$JAEGER_PORT" ]; then
    echo "Jaeger Query API port not found for service ${JAEGER_SERVICE_NAME}"
    exit 1
fi

LOCAL_PORT=16686 # Local port for port-forwarding
REMOTE_PORT=$JAEGER_PORT

# Start port-forwarding in the background
${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} port-forward service/${JAEGER_SERVICE_NAME} ${LOCAL_PORT}:${REMOTE_PORT} -n ${NAMESPACE} &
PF_PID=$!

# Wait a bit for the port-forward to establish
sleep 5

# Jaeger Query base URL using the forwarded port
JAEGER_QUERY_BASE_URL="http://localhost:${LOCAL_PORT}"

# Query and process service health
echo "--------"
echo "Fetching all available services from Jaeger..."
services=$(curl -s "${JAEGER_QUERY_BASE_URL}/api/services" | jq -r '.data[]')
echo "Available services:"
echo "${services}"
echo "--------"


# Iterate over each service to fetch and store their traces from the last 5 minutes
declare -A traces
# Fetch traces for each service and store in associative array
for service in $services; do
    echo "Fetching traces for service: $service from the last $LOOKBACK..."
    traces["$service"]=$(curl -s "${JAEGER_QUERY_BASE_URL}/api/traces?service=${service}&lookback=${LOOKBACK}&limit=1000")
    # echo "${traces["$service"]}" > "${service}_traces.json"

done




# Cleanup: Stop the port-forwarding process
echo "--------"
echo "Clean up port-forward process."
kill $PF_PID
echo "Port-forwarding stopped."
echo "--------"

SPACE_SEPARATED_EXCLUSIONS=" ${SERVICE_EXCLUSIONS//,/ } "


# Process Traces
for service in "${!traces[@]}"; do
    if [[ $SPACE_SEPARATED_EXCLUSIONS =~ " $service " ]]; then
        echo "Skipping service $service - found in SERVICE_EXCLUSIONS configuration"
    else
        echo "--------"
        echo "Processing traces for service: $service"
        # Access each service's traces using ${traces[$service]}
        service_errors=$(echo "${traces["$service"]}" | jq '
        # Define dictionaries for status codes and descriptions
        def httpStatusDescriptions: {
            "400": "Bad Request",
            "401": "Unauthorized",
            "403": "Forbidden",
            "404": "Not Found",
            "500": "Internal Server Error",
            "501": "Not Implemented",
            "502": "Bad Gateway",
            "503": "Service Unavailable",
            "504": "Gateway Timeout"
        };

        # Normalize and process traces
        [.data[].spans[] |
        {
            traceID: .traceID,
            spanID: .spanID,
            route_or_url: (
            [.tags[] | select(.key == "http.route" or .key == "http.url").value][0] // "unknown"
            | if test("http[s]?://[^/]+/[^/]+") then split("/")[0:3] | join("/") else . end
            ),
            status_code: (.tags[] | select(.key == "http.status_code").value | tostring | tonumber)
        }] |
        map(select(.status_code != 200)) |
        group_by(.route_or_url) |
        map({
            route_or_url: .[0].route_or_url,
            by_status_code: group_by(.status_code) | 
            map({
            status_code: .[0].status_code,
            status_description: (
                .[0].status_code | tostring | 
                if httpStatusDescriptions[.] then httpStatusDescriptions[.] else "Unknown Status Code" end
            ),
            traces: map({traceID: .traceID, spanID: .spanID})
            })
        })
        ')
        while IFS= read -r line; do
            route_or_url=$(echo "$line" | jq '.route_or_url')
            # Initialize the recommendation variable
            issue_details=""
            
            while IFS= read -r error; do
                status_code=$(echo "$error" | jq '.status_code')
                status_description=$(echo "$error" | jq -r '.status_description')
                # Generate issue_details based on the status code
                case "$status_code" in
                    400) 
                        http_error_recommendation="Check the request syntax."
                        details=$(printf '%s' "${line}" | sed 's/"/\\"/g')
                        issue_details="{\"severity\":\"4\",\"service\":\"$service\",\"title\":\"HTTP Error 400 ($status_description) found for service \`$service\` in namespace \`${NAMESPACE}\`\",\"next_steps\":\"Review issue details for traceIDs and review in Jaeger.\",\"details\":\"View traces in Jaeger and $http_error_recommendation:\\n$details\"}" ;;
                    401) 
                        http_error_recommendation="Ensure proper authentication."
                        details=$(printf '%s' "${line}" | sed 's/"/\\"/g')
                        issue_details="{\"severity\":\"4\",\"service\":\"$service\",\"title\":\"HTTP Error 401 ($status_description) found for service \`$service\` in namespace \`${NAMESPACE}\`\",\"next_steps\":\"Review issue details for traceIDs and review in Jaeger.\",\"details\":\"View traces in Jaeger and $http_error_recommendation:\\n$details\"}" ;;
                    403) 
                        http_error_recommendation="Check permissions."
                        details=$(printf '%s' "${line}" | sed 's/"/\\"/g')
                        issue_details="{\"severity\":\"4\",\"service\":\"$service\",\"title\":\"HTTP Error 403 ($status_description) found for service \`$service\` in namespace \`${NAMESPACE}\`\",\"next_steps\":\"Review issue details for traceIDs and review in Jaeger.\",\"details\":\"View traces in Jaeger and $http_error_recommendation:\\n$details\"}" ;;
                    404) 
                        http_error_recommendation="Verify the URL or resource."
                        details=$(printf '%s' "${line}" | sed 's/"/\\"/g')
                        issue_details="{\"severity\":\"4\",\"service\":\"$service\",\"title\":\"HTTP Error 404 ($status_description) found for service \`$service\` in namespace \`${NAMESPACE}\`\",\"next_steps\":\"Review issue details for traceIDs and review in Jaeger.\",\"details\":\"View traces in Jaeger and $http_error_recommendation:\\n$details\"}" ;;
                    500) 
                        http_error_recommendation="Investigate server-side errors." 
                        details=$(printf '%s' "${line}" | sed 's/"/\\"/g')
                        issue_details="{\"severity\":\"4\",\"service\":\"$service\",\"title\":\"HTTP Error 500 ($status_description) found for service \`$service\` in namespace \`${NAMESPACE}\`\",\"next_steps\":\"Review issue details for traceIDs and review in Jaeger.\\nCheck Log for Issues with \`$service\`\\nCheck Warning Events for \`$service\`\",\"details\":\"View traces in Jaeger and $http_error_recommendation:\\n$details\"}" ;;
                    # Add more cases as needed
                    *) 
                        http_error_recommendation="No specific recommendation." ;;
                esac
                echo $issue_details

                # Initialize issues as an empty array if not already set
                if [ -z "$issues" ]; then
                    issues="[]"
                fi

                # Concatenate issue detail to the string
                if [ -n "$issue_details" ]; then
                    # Remove the closing bracket from issues to prepare for adding a new item
                    issues="${issues%]}"

                    # If issues is not an empty array (more than just "["), add a comma before the new item
                    if [ "$issues" != "[" ]; then
                        issues="$issues,"
                    fi

                    # Add the new issue detail and close the array
                    issues="$issues $issue_details]"
                fi

            done <<< "$(echo "$line" | jq -c '.by_status_code[]')"
        done <<< "$(echo "$service_errors" | jq -c '.[]')"
    fi
done



# Display all unique recommendations that can be shown as Next Steps
if [ -n "$issues" ]; then
    echo -e "\nRecommended Next Steps: \n"
    echo "$issues"
fi