# GCP Log Inspection

Runs a task which performs an inspection on your logs in a GCP project, returning results regarding common issues, counts and related Kubernetes namespaces using a filter.

## Tasks
`Inspect GCP Logs For Common Errors`

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `SEVERITY`: What severity to filter on, this will be the minimum severity returned in the log results.
- `ADD_FILTERS`: An optional filter that can be added to the log query to customize results further.
- `GCLOUD_SERVICE`: The remote gcloud service to use for requests.
- `gcp_credentials`: The json credentials secrets file used to authenticate with the GCP project. Should be a service account.
- `GCP_PROJECT_ID`: The unique project ID identifier string.

## Notes

The `gcp_credentials` service account will need view and list permissions on the GCP logging API.

## Requirements

This codebundle authenticates with a GCP service account (`gcp_credentials`, activated via `gcloud auth activate-service-account`) scoped to `${GCP_PROJECT_ID}`, and reads log entries via `gcloud logging read`. The following IAM permission is required on the service account:

**Granular IAM permissions**
- `logging.logEntries.list` — `gcloud logging read` calls the Cloud Logging `entries.list` method

**Suggested predefined role(s)**
- `roles/logging.viewer` — covers `logging.logEntries.list` (least-privilege fit for standard logs)
- `roles/logging.privateLogViewer` — only if the query must also return Data Access / private audit logs (adds `logging.privateLogEntries.list`)

> Requires the Cloud Logging API (`logging.googleapis.com`) enabled on the project.

## TODO
- [ ] Add documentation
- [ ] Add IAM settings examples
- [ ] Add flexible result breakdown behaviour for non-kubernetes projects
- [ ] Refine raised issues