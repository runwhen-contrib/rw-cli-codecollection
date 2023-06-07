# Kubernetes Deployment Triage

This codebundle provides a suite of tasks aimed at triaging issues related to a deployment and its replicas in Kubernetes clusters.

## Tasks
`Get Deployment Log Details For Report`
`Troubleshoot Deployment Warning Events`
`Get Deployment Workload Details For Report`
`Troubleshoot Deployment Replicas`

## Configuration
The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `kubectl`: The location service used to interpret shell commands. Default value is `kubectl-service.shared`.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search. Leave it blank to search in all namespaces.
- `DEPLOYMENT_NAME`: The name of the deployment.
- `EXPECTED_AVAILABILITY`: The number of replicas allowed.

## Requirements
- A kubeconfig with appropriate RBAC permissions to perform the desired command.

## TODO
- [ ] Add additional documentation.

