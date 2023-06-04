# GCP GMP Nginx Ingress Inspection

Runs a task which performs inspects the HTTP error code metrics related to your nginx ingress controller in your GKE kubernetes cluster and raises issues based on the number of ingress with errors.

## Tasks
`Fetch Nginx Ingress Metrics From GMP And Perform Inspection On Results`

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `PROMQL_STATEMENT`: The promql statement to run to fetch nginx ingress metrics. Defaults to `rate(nginx_ingress_controller_requests{status=~${ERROR_CODES}}[${TIME_SLICE}]) > 0` which allows it to be injected with other configuration values.
- `TIME_SLICE`: What duration to calculate the rate over. Defaults to 60 minutes.
- `ERROR_CODES`: Which HTTP codes to consider as errors. defaults to 500, 501, and 502.
- `GCLOUD_SERVICE`: The remote gcloud service to use for requests.
- `gcp_credentials_json`: The json credentials secrets file used to authenticate with the GCP project. Should be a service account.
- `GCP_PROJECT_ID`: The unique project ID identifier string.

## Notes

The `gcp_credentials_json` service account will need view and list permissions on the GCP logging API.

## TODO
- [ ] Add documentation
- [ ] Add examples for non-gke ingress objects for other cloud projects
- [ ] Add IAM settings examples