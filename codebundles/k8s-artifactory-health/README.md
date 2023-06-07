# Kubernetes Artifactory Triage

This codebundle queries the health REST endpoints of an Artifactory workload in Kubernetes, checking if the service is healthy, and raising issues if it's not.

## Tasks
`Check Artifactory Liveness and Readiness Endpoints`

## Configuration
The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `kubectl`: The location service used to interpret shell commands. Default value is `kubectl-service.shared`.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search. Leave it blank to search in all namespaces.
- `DEPLOYMENT_NAME`: The name of the deployment running Redis
- `EXPECTED_AVAILABILITY`: The number of replicas allowed.
- `LABELS`: Labels used for selecting the workload(s).

## Requirements
- A kubeconfig with appropriate RBAC permissions to perform the desired command.

## TODO
- [ ] Add additional documentation.