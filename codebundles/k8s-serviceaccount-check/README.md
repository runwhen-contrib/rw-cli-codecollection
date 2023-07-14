# Kubernetes Service Account Check

Tasks that help debug or validate service accounts and their access. 

## Tasks
- `Test Service Account Access to Kubernetes API Server`- Runs a curl pod as a specific serviceaccount and attempts to all the Kubernetes API server with the mounted token


## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `kubectl`: The location service used to interpret shell commands. Default value is `kubectl-service.shared`.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search.
- `SERVICE_ACCOUNT`: The service account to test access with. Defaults to `default`

## Requirements
This task creates and deletes a pod in the specified namespace, RBAC permissions must support this. 

## TODO
- [ ] Add documentation
- [ ] Add github integration with source code vs image comparison
- [ ] Find applicable raise issue use