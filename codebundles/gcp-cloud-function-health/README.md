# GCP Cloud Function Health
This code checks if any GCP (Google Cloud Platform) cloud functions are unhealthy. It uses the gcloud command-line tool to interact with GCP APIs and retrieve the necessary information.


## SLI
The SLI counts the number of cloud functions that are "FAILED" state and pushes the metric. 

## TaskSet 
The Taskset lists provides the following tasks: 

- List failed Cloud Functions in GCP Project
- Get Error Logs for Failed Cloud Functions in GCP Project

## Requirements
The following permissions are required on the GCP service account used with the gcloud utility: 

 - `cloudfunctions.functions.get`
 - `cloudfunctions.functions.list`