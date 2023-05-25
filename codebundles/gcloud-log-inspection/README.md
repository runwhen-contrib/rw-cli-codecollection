# GCP Log Inspection

Runs a task which performs an inspection on your logs in a GCP project, returning results regarding common issues, counts and related Kubernetes namespaces using a filter.

## Tasks
`Inspect GCP Logs For Common Errors`

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `SEVERITY`: What severity to filter on, this will be the minimum severity returned in the log results.
- `ADD_FILTERS`: An optional filter that can be added to the log query to customize results further.
- `GCLOUD_SERVICE`: The remote gcloud service to use for requests.
- `gcp_credentials_json`: The json credentials secrets file used to authenticate with the GCP project. Should be a service account.
- `GCP_PROJECT_ID`: The unique project ID identifier string.

## Notes

The `gcp_credentials_json` service account will need view and list permissions on the GCP logging API.

## TODO
- [ ] Add documentation
- [ ] Add IAM settings examples
- [ ] Add flexible result breakdown behaviour for non-kubernetes projects
- [ ] Refine raised issues