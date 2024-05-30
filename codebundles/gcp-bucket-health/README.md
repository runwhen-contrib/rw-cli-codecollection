# GCP Bucket Health
This code checks if any GCP (Google Cloud Platform) buckets are unhealthy, focusing on: 
- Utilization  (with a user defined threshold for issue/alert generation)
- Security Configuration (with a user defined threshold on when to generate issues/alerts for publicly accessible buckets)


## SLI
The SLI: 
- counts the number of buckets that are above the user defined threshold
- counts the number of publicly accessible buckets above the user defined threshold

## TaskSet 
The Taskset lists provides the following tasks: 

- Fetch GCP Bucket Storage Utilization for `${PROJECT_IDS}`
- Add GCP Bucket Storage Configuration for `${PROJECT_IDS}` to Report
- Check GCP Bucket Security Configuration for `${PROJECT_IDS}`

## Requirements
The following roles are useful on the GCP service account used with the gcloud utility: 

- Viewer
- Security Reviewer

## TODO 
Update required GCP SA permissions. 