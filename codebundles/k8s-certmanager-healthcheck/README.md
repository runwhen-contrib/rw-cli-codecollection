# Kubernetes CertManager Triage

This taskset checks that certmanager is renewing certificates as expected within a namespace and raises issues when certificates are not renewing as expected.

## Tasks
`Get Namespace Certificate Summary`

## Configuration
The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `kubectl`: The location service used to interpret shell commands. Default value is `kubectl-service.shared`.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search. Leave it blank to search in all namespaces.

## Requirements
- A kubeconfig with appropriate RBAC permissions to perform the desired command.

## TODO
- [ ] Add additional documentation.

