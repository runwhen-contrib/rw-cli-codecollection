# Kubernetes Application Troubleshoot

x
## Tasks
`Get Resource Logs`
`Scan For Misconfigured Environment`
`Troubleshoot Application Logs`

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
- `CREATE_ISSUES`: A boolean flag whether or not to create github issues for the related parsed exceptions.
- `LOGS_SINCE`: How far back to scan for logs, eg: 20m, 3h
- `EXCLUDE_PATTERN`: a extended grep pattern used to filter out log results, such as exceptions/errors that you don't care about.
- `CONTAINER_NAME`: the name of the container within the labeled workload to fetch logs from.
- `MAX_LOG_LINES`: The maximum number of logs to fetch. Setting this too high can effect performance.

## Requirements
- A kubeconfig with appropriate RBAC permissions to perform the desired command, particularly exec
- A oauth token for github authentication, with read permissions on repositories(s) and write permissions on issues.

## Automated Building
Additionally you must have the following manifest changes in order for workspace builder to automatically setup this codebundle for you:

- A deployment with the follow annotations and labels:
    -   annotations.gitApplication: YOUR_GIT_URL
    -   annotations.gitTokenName: THE_WORKSPACE_TOKEN_NAME
    -   labels.app: app name that matches the container name in the pod to pull logs from

## TODO
- [ ] New keywords for code inspection
- [ ] SPIKE for potential genAI integration
- [ ] Add additional documentation.

