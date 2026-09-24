# Kubernetes Ingress-GCE HealthCheck

Triages the GCP HTTP Load Balancer resources that are created when an ingress object is detected and created by the ingress-gce controller.   

## Tasks
- `Search For GCE Ingress Warnings in GKE`-  Executes CLI commands to find warning events related to GCE Ingress and services objects. Parses the CLI output to identify and report issues.

- `Identify Unhealthy GCE HTTP Ingress Backends` - Uses CLI commands to check the backend annotations on the Ingress object for health issues. Parses the CLI output to identify and report unhealthy backends.

- `Validate GCP HTTP Load Balancer Configurations` Executes bash scripts to validate GCP HTTP Load Balancer components extracted from Ingress annotations. Parses the output for issues and recommendations.

- `Fetch Network Error Logs from GCP Operations Manager for Ingress Backends` - Executes CLI commands to fetch network error logs for Ingress backends. Parses the CLI output to identify and report network error issues.

- `Review GCP Operations Logging Dashboard`: Generates URLs to access GCP Operations Logging Dashboard for Load Balancer logs and backend logs.

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search.
- `INGRESS`: The name of the ingress object to triage. 
- `GCP_PROJECT_ID`: The id of the gcp project to query. 
- `gcp_credentials`: The name of the secret that contains GCP service account json details with project `Viewer` access. 


## Requirements

This codebundle uses two independent credentials:

1. A GCP service account (`gcp_credentials`, activated via `gcloud auth activate-service-account`) scoped to `${GCP_PROJECT_ID}`, used to inspect the GCE (Ingress-GCE) load-balancer resources backing the Ingress and to read network error logs.
2. A `kubeconfig` with Kubernetes RBAC read (get/list) access to Ingress, Service, and Event objects in the target namespace (the GCE resource names are read from the Ingress annotations).

The following GCP IAM permissions are required on the service account (all read-only):

**Granular IAM permissions**
- `compute.forwardingRules.get` — `gcloud compute forwarding-rules describe`
- `compute.urlMaps.get` — `gcloud compute url-maps describe`
- `compute.targetHttpsProxies.get` — `gcloud compute target-https-proxies describe`
- `compute.targetHttpProxies.get` — `gcloud compute target-http-proxies describe`
- `compute.backendServices.get` — `gcloud compute backend-services get-health` (reads the backend service)
- `compute.backendServices.getHealth` — `gcloud compute backend-services get-health` (backend health status)
- `logging.logEntries.list` — `gcloud logging read` (GCE network error logs)

**Suggested predefined role(s)**
- `roles/compute.viewer` — covers all the `compute.*` reads above
- `roles/logging.viewer` — covers `logging.logEntries.list`

> Requires the Compute Engine (`compute.googleapis.com`) and Cloud Logging (`logging.googleapis.com`) APIs enabled on the project. Kubernetes access is authenticated separately via the `kubeconfig` secret — GCP IAM does not grant cluster RBAC.

## TODO
- [ ] Add documentation
- [ ] Add github integration with source code vs image comparison
- [ ] Find applicable raise issue use