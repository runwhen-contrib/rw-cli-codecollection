# Kubernetes Tail Application Logs For Stacktraces

This codebundle attempts to identify issues created in application code changes recently. 
In order for it to appear in your workspace, just add the following annotation to your application deployments:
`runwhenAppContainerName` with the value being the name of the container in the deployment to search for stacktraces.

## Configuration
The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `kubectl`: The location service used to interpret shell commands. Default value is `kubectl-service.shared`.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search. Leave it blank to search in all namespaces.
- `LABELS`: The labaels used for resource selection, particularly for fetching logs.
- `LOGS_SINCE`: How far back to scan for logs, eg: 20m, 3h
- `EXCLUDE_PATTERN`: a extended grep pattern used to filter out log results, such as exceptions/errors that you don't care about.
- `CONTAINER_NAME`: the name of the container within the labeled workload to fetch logs from.
- `MAX_LOG_LINES`: The maximum number of logs to fetch. Setting this too high can effect performance.
- `STACKTRACE_PARSER`: What parser to use on log lines. If left as Dynamic then the first one to return a result will be used for the rest of the logs to parse.
- `INPUT_MODE`: Determines how logs are fed into the parser. Typically the default should work.
- `MAX_LOG_BYTES`: Maximum number of bytes to fetch for logs from containers.

## Requirements
- A kubeconfig with appropriate RBAC permissions to perform the desired command, particularly exec

## Automated Building
Additionally you must have the following manifest changes in order for workspace builder to automatically setup this codebundle for you:

- A deployment with the follow annotations and labels:
    -   annotations.runwhenAppContainerName: the name of the container in the pod to search for stacktraces
    -   labels.app: selector used to grab logs from pods across a deployment

## TODO
- [ ] Add additional documentation.
- [ ] Finish suggestions error msg lookup

