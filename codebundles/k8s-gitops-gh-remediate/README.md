# Kubernetes GitOps GitHub Remediate

This codebundle provides a suite of tasks aimed at remediating configuration issues related to Kubernetes deployments managed in github repositories.

## Tasks
`Remediate Readiness and Liveness Probe GitOps Manifests in Namespace`
`Increase ResourceQuota for Namespace`
`Adjust Pod Resources to Match VPA Recommendation in`

## Configuration
The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search. Leave it blank to search in all namespaces.

## Requirements
- A kubeconfig with appropriate RBAC permissions to perform the desired command.

## TODO
- [ ] Add additional documentation.

