# GCP Cloud Function Health
This code checks if any GCP (Google Cloud Platform) cloud functions are unhealthy. It uses the gcloud command-line tool to interact with GCP APIs and retrieve the necessary information.

> Note: Only cloud functions v1 is supported at this time for automatic discovery with the RunWhen Local Discovery Process. The tasks will support either generation. 

## SLI
The SLI counts the number of cloud functions that are "FAILED" state and pushes the metric. 

## TaskSet 
The Taskset lists provides the following tasks: 

- List Unhealhy Cloud Functions in GCP Project
- Get Error Logs for Unhealthy Cloud Functions in GCP Project

## Requirements
The following permissions are required on the GCP service account used with the gcloud utility: 

 - `cloudfunctions.functions.get`
 - `cloudfunctions.functions.list`