# Kubernetes Application Troubleshoot

This codebundle attempts to identify issues created in application code changes recently. Currently focuses on environment misconfigurations.

## Tasks
`Get Resource Logs`
`Scan For Misconfigured Environment`

## Configuration
The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `kubectl`: The location service used to interpret shell commands. Default value is `kubectl-service.shared`.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search. Leave it blank to search in all namespaces.
- `LABELS`: The labaels used for resource selection, particularly for fetching logs.
- `REPO_URI`: The URI for the git repo used to fetch source code, can be a GitHub URL.
- `NUM_OF_COMMITS`: How many commits to search through into the past to identify potential problems.

## Requirements
- A kubeconfig with appropriate RBAC permissions to perform the desired command.

## TODO
- [ ] New keywords for code inspection
- [ ] SPIKE for potential genAI integration
- [ ] Add additional documentation.

