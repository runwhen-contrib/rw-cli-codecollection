# Kubernetes Deployment Triage

This codebundle provides a suite of operational tasks related to a deployment in Kubernetes clusters.

## Tasks
- Restart Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
- Force Delete Pods in Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
- Rollback Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}` to Previous Version
- Scale Down Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
- Scale Up Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}` by ${SCALE_UP_FACTOR}x
- Clean Up Stale ReplicaSets for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
- Scale Down Stale ReplicaSets for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`


## Configuration
The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search. Leave it blank to search in all namespaces.
- `DEPLOYMENT_NAME`: The name of the deployment.
- `SCALE_UP_FACTOR`: A multiple in which to increase replicas by
## Requirements
- A kubeconfig with appropriate RBAC permissions to perform the desired command.

## TODO
- [ ] Add additional documentation.

