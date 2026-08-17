# GCP GMP Nginx Ingress Inspection

Runs a task which performs inspects the HTTP error code metrics related to your nginx ingress controller in your GKE kubernetes cluster and raises issues based on the number of ingress with errors.

## Tasks
`Fetch Nginx Ingress Metrics From GMP And Perform Inspection On Results` - This task fetchs the HTTP metrics from GMP, and also uses kubectl to fetch details about the ingress object, it's health, and the service owner. 

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `TIME_SLICE`: What duration to calculate the rate over. Defaults to 60 minutes.
- `ERROR_CODES`: Which HTTP codes to consider as errors. defaults to 500, 501, and 502.
- `GCLOUD_SERVICE`: The remote gcloud service to use for requests.
- `gcp_credentials`: The json credentials secrets file used to authenticate with the GCP project. Should be a service account.
- `GCP_PROJECT_ID`: The unique project ID identifier string.
- `INGRESS_OBJECT_NAME`: The Kubernetes ingress object name.
- `INGRESS_SEVICE`: The Kubernetes service name behind the ingress object.
- `INGRESS_HOST`: The hostname of the ingress object.
- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `kubectl`: The location service used to interpret shell commands. Default value is `kubectl-service.shared`.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the Ingress object.

## Notes

The `gcp_credentials` service account queries Google Managed Prometheus (GMP) metrics through the Cloud Monitoring API.
The `kubectl secret` will need to get|list the ingress object, services, pods, deployments, relicasets, statefulsets and so on in the namespace. 

## Requirements

This codebundle uses two independent credentials:

1. A GCP service account (`gcp_credentials`, activated via `gcloud auth activate-service-account`) scoped to `${GCP_PROJECT_ID}`, used to query Google Managed Prometheus through the Cloud Monitoring `prometheus/api/v1/query` endpoint.
2. A `kubeconfig` with Kubernetes RBAC read (get/list) access to Ingress, Service, Endpoints, Pod, and ReplicaSet objects in the target namespace.

The following GCP IAM permission is required on the service account:

**Granular IAM permissions**
- `monitoring.timeSeries.list` — run the PromQL query against the GMP / Cloud Monitoring query endpoint (metric `nginx_ingress_controller_requests`)

**Suggested predefined role**
- `roles/monitoring.viewer` — covers `monitoring.timeSeries.list` (least-privilege fit)

> Requires the Cloud Monitoring API (`monitoring.googleapis.com`) enabled on the project, with Google Managed Prometheus ingesting the ingress-nginx metrics. Kubernetes access is authenticated separately via the `kubeconfig` secret (no GKE `container.*` IAM permission is consumed).

## TODO
- [ ] Add documentation
- [ ] Add examples for non-gke ingress objects for other cloud projects
- [ ] Add IAM settings examples