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


## TODO
- [ ] Add documentation
- [ ] Add github integration with source code vs image comparison
- [ ] Find applicable raise issue use