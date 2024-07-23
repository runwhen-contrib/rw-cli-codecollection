# Kubernetes OpenTelemetry Health Check
Checks the OTEL collector's logs and metrics to determine its health, such as large queues or errors.

Note: if you're having trouble connecting to your otel collector, change the
 deployment name to another workload in the namespace

## Tasks
`Scan OpenTelemetry Logs For Dropped Spans In Namespace `

`Check OpenTelemetry Collector Logs For Errors In Namespace`

`Query Collector Queued Spans in Namespace`

## Configuration
The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search. Leave it blank to search in all namespaces.
- `WORKLOAD_SERVICE`: Service name to curl against for metrics.
- `WORKLOAD_NAME`: Workload used for exec requests.
- `METRICS_PORT`: The port to use to request metrics from.


## Requirements
- A kubeconfig with appropriate RBAC permissions to perform the desired command.

## TODO
- [ ] Consider additional tasks

