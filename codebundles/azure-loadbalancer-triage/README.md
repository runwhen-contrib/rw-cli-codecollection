# Azure LoadBalancer Triage

Queries the activity logs of internal loadbalancers (AKS ingress) objects in Azure and optionally inspects internal AKS ingress objects if available.

## Tasks
`Health Check Azure Load Balancer`
`Fetch Azure Ingress Object Health in Namespace``

## Configuration
The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `kubectl`: The location service used to interpret shell commands. Default value is `kubectl-service.shared`.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search.
- `LABELS`: The labels used for resource selection, particularly for fetching logs.
- `SKIP_K8S`: Configuration to disable the kubernetes ingress check if the API is not publically available (skips by default).
- `AZ_USERNAME`: Azure service account username secret used to authenticate.
- `AZ_CLIENT_SECRET`: Azure service account client secret used to authenticate.
- `AZ_TENANT`: Azure tenant ID used to authenticate to.
- `AZ_HISTORY_RANGE`: The history range to inspect for incidents in the activity log, in hours. Defaults to 24 hours.

## Requirements
- A kubeconfig with appropriate RBAC permissions to perform the desired command.

## TODO
- [ ] Refine issues raised
- [ ] Look at cross az/kubectl support and if keeping it in this codebundle makes sense
- [ ] Add additional documentation.

