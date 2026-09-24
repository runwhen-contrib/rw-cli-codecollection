# GCP GMP Kong Ingress Inspection

This code collects Kong ingress host metrics from Google Monitoring Platform (GMP) on Google Cloud Platform (GCP) and inspects the results for ingresses with a HTTP error code rate greater than zero over a configurable duration. It raises issues based on the number of ingresses with error codes.

## Tasks
- `Check If Kong Ingress HTTP Error Rate Violates HTTP Error Threshold` - This task fetches HTTP error metrics for the Kong ingress host and service from GMP and performs an inspection on the results. If there are currently any results with more than the defined HTTP error threshold, their route and service names will be surfaced for further troubleshooting.
- `Check If Kong Ingress HTTP Request Latency Violates Threshold` - This task fetches metrics for the Kong ingress 99th percentile request latency from GMP and performs an inspection on the results. If there are currently any results with request latencies greater than the defined threshold, their route and service names will be surfaced for further troubleshooting.
- `Check If Kong Ingress Controller Reports Upstream Errors` - This task fetches metrics for the Kong ingress controller related to upstream health checks or DNS errors. It checks if health checks are enabled for the specified upstream target and if there are any reported health check errors. The results are surfaced for further investigation.

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `TIME_SLICE`: What duration to calculate the rate over. Defaults to 1m.
- `HTTP_ERROR_CODES`: Which HTTP codes to consider as errors. defaults to all 500 error codes. 
- `HTTP_ERROR_RATE_THRESHOLD`: Specify the error rate threshold that is considered unhealthy. Measured in errors/s
- `REQUEST_LATENCY_THRESHOLD`: The threshold in ms for request latency to be considered unhealthy. 
- `GCLOUD_SERVICE`: The remote gcloud service to use for requests.
- `gcp_credentials`: The json credentials secrets file used to authenticate with the GCP project. Should be a service account.
- `GCP_PROJECT_ID`: The unique project ID identifier string.

## Notes

The `gcp_credentials` service account queries Google Managed Prometheus (GMP) metrics through the Cloud Monitoring API.

## Requirements

This codebundle authenticates with a GCP service account (`gcp_credentials`, activated via `gcloud auth activate-service-account`) scoped to `${GCP_PROJECT_ID}`, and queries Google Managed Prometheus through the Cloud Monitoring `prometheus/api/v1/query` endpoint. The following IAM permission is required on the service account:

**Granular IAM permissions**
- `monitoring.timeSeries.list` — run the PromQL queries against the GMP / Cloud Monitoring query endpoint

**Suggested predefined role**
- `roles/monitoring.viewer` — covers `monitoring.timeSeries.list` (least-privilege fit)

> Requires the Cloud Monitoring API (`monitoring.googleapis.com`) enabled on the project, with Google Managed Prometheus ingesting the Kong ingress metrics (`kong_http_requests_total`, `kong_request_latency_ms_bucket`, `kong_upstream_target_health`).

## TODO
- [ ] Add documentation
- [ ] Add examples for non-gke ingress objects for other cloud projects
- [ ] Add IAM settings examples