# gcloud Node Preempt List
This code checks if any GCP (Google Cloud Platform) nodes have an active preempt operation. It uses the gcloud command-line tool to interact with GCP APIs and retrieve the necessary information.


## SLI
The SLI lists all preempt node operations that have a status that does not match "DONE", counts the total nodes in this state, and pushes the metric. 

## TaskSet 
The Taskset lists all preempt node operations that have a status that does not match "DONE" and returns the following details in json format: 

- startTime
- targetLink
- statusMessage
- progress
- zone
- selfLink 


## Requirements
The following permissions are required on the GCP service account used with the gcloud utility: 

 - 'compute.globalOperations.list'