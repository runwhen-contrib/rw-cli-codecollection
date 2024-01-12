# Kubernetes Namespace Triage
This codebundle is used for searching in a namespace for possible issues to triage; covering things such as scraping logs, checking for anomalies in events, looking for pod restarts, etc. These tasks can be performed with just native kubernetes objects and do not require additional logging / tracing tools be setup by the user. Problems identified during triage will result in raised issues.

## Tasks

`Trace And Troubleshoot Namespace Warning Events And Errors`
`Troubleshoot Unready Pods In Namespace For Report`
`Troubleshoot Workload Status Conditions In Namespace`
`Get Listing Of Workloads In Namespace`
`Check For Namespace Event Anomalies`
`Check Missing or Risky PodDisruptionBudget Policies`


## Configuration
The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `kubectl`: The location service used to interpret shell commands. Default value is `kubectl-service.shared`.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search. Leave it blank to search in all namespaces.
- `ERROR_PATTERN`: What error pattern to grep for in logs when tracing issues.
- `SERVICE_ERROR_PATTERN`: The error pattern used when extracting and summarizing error logs from services.
- `SERVICE_EXCLUDE_PATTERN`: What patterns used to exclude results when checking service logs in a namespace. Useful to reduce noise.
- `ANOMALY_THRESHOLD`: What non-warning event count constitutes an anomaly for raising issues.

## Requirements
- A kubeconfig with appropriate RBAC permissions to perform the desired command.

## TODO
- [ ] Add additional documentation.

