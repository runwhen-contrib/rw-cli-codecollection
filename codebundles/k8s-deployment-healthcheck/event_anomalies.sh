#!/bin/bash

# Assuming environment variables are already exported and available

# Command to get Kubernetes events in JSON format
EVENTS_JSON=$(${KUBERNETES_DISTRIBUTION_BINARY} get events --context ${CONTEXT} -n ${NAMESPACE} -o json)

# Use jq to process the JSON, skipping events without valid timestamps
PROCESSED_EVENTS=$(echo "${EVENTS_JSON}" | jq --arg DEPLOYMENT_NAME "${DEPLOYMENT_NAME}" '
  [ .items[]
    | select(
        .type != "Warning"
        and (.involvedObject.kind | test("Deployment|ReplicaSet|Pod"))
        and (.involvedObject.name | contains($DEPLOYMENT_NAME))
        and (.firstTimestamp | fromdateiso8601? // empty) and (.lastTimestamp | fromdateiso8601? // empty)
        # Filter out events with unknown or missing object names
        and .involvedObject.name != null 
        and .involvedObject.name != "" 
        and .involvedObject.name != "Unknown"
        and .involvedObject.kind != null 
        and .involvedObject.kind != ""
      )
    | {
        kind: .involvedObject.kind,
        count: .count,
        name: .involvedObject.name,
        reason: .reason,
        message: .message,
        firstTimestamp: .firstTimestamp,
        lastTimestamp: .lastTimestamp,
        duration: (
          if (((.lastTimestamp | fromdateiso8601) - (.firstTimestamp | fromdateiso8601)) == 0)
          then 1
          else (((.lastTimestamp | fromdateiso8601) - (.firstTimestamp | fromdateiso8601)) / 60)
          end
        )
      }
  ]
  | group_by([.kind, .name])
  | map({
      kind: .[0].kind,
      name: .[0].name,
      count: (map(.count) | add),
      reasons: (map(.reason) | unique),
      messages: (map(.message) | unique),
      average_events_per_minute: (
        if .[0].duration == 1
        then 1
        else ((map(.count) | add) / .[0].duration)
        end
      ),
      firstTimestamp: (map(.firstTimestamp | fromdateiso8601) | sort | .[0] | todateiso8601),
      lastTimestamp: (map(.lastTimestamp | fromdateiso8601) | sort | reverse | .[0] | todateiso8601)
    })
')

echo "${PROCESSED_EVENTS}"
