# Kubernetes Deployment Triage

This codebundle provides a suite of operational tasks related to a deployment in Kubernetes clusters.

## Tasks
`Restart Deployment`

## Configuration
The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search. Leave it blank to search in all namespaces.
- `DEPLOYMENT_NAME`: The name of the deployment.
- `EXPECTED_AVAILABILITY`: The number of replicas allowed.

## Requirements
- A kubeconfig with appropriate RBAC permissions to perform the desired command.

## TODO
- [ ] Add additional documentation.

