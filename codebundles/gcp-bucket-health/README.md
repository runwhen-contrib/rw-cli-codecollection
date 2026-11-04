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

This codebundle authenticates with a GCP service account (`gcp_credentials`, activated via `gcloud auth activate-service-account`) and inspects every project listed in `${PROJECT_IDS}` using `gcloud storage`, `gsutil`, and the Cloud Monitoring API. All operations are read-only. The permissions below must be granted in **each** target project (or a shared ancestor folder/org).

**Granular IAM permissions**
- `storage.buckets.list` — `gsutil ls -p <project>` (enumerate buckets)
- `storage.buckets.get` — `gcloud storage buckets describe` (bucket metadata / encryption / IAM config)
- `storage.buckets.getIamPolicy` — `gcloud storage buckets get-iam-policy` and `gsutil acl get` (public-access / security check)
- `storage.objects.list` — `gsutil du -s gs://<bucket>` (object-size fallback when the Monitoring API is disabled)
- `monitoring.timeSeries.list` — Cloud Monitoring PromQL queries for bucket size and read/write op rates
- `serviceusage.services.list` — `gcloud services list --enabled` (detect whether the Monitoring API is on)

**Suggested predefined role(s)**
- `roles/iam.securityReviewer` — covers `storage.buckets.list/get/getIamPolicy` (bucket + IAM/ACL reads with no write access)
- `roles/storage.objectViewer` — covers `storage.objects.list` (the `gsutil du` size fallback)
- `roles/monitoring.viewer` — covers `monitoring.timeSeries.list`
- `roles/serviceusage.serviceUsageViewer` — covers `serviceusage.services.list`

> `roles/storage.admin` is **not** needed — nothing here writes, deletes, or sets IAM. Requires the Cloud Storage, Cloud Monitoring, and Service Usage APIs enabled on each project.

## Local testing
- need `gcloud` SDK in the test-bed(docker container)
- `gcloud auth login`
- to test in your environment: `gcloud config set project my-gcp-project`
- you would also need to set application-default credentials if you don't have service-account keys:
    - `gcloud auth application-default login`
