# Kubernetes Jaeger HTTP Query
This codebundle is used for searching in a Jaeger instance for trace data that indicates issues with services.

## Tasks

`Query Traces in Jaeger instance for Unhealthy HTTP Response Codes in Namespace`  
Locates the Jaeger query service in the configured namespace, port-forwards the service, and queries for all traces within the LOOKBACK period (5m by default) for every available service. Then processes the results and generates issues and next steps for non 200 http error codes. 


## Configuration
The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search. Leave it blank to search in all namespaces.
- `SERVICE_EXCLUSIONS`: Optional. Services in Jaegar to ignore during trace analysis.
- `LOOKBACK`: Optional. The age of traces to include in the query. Defaults to 5m (5 Minutes)

## Requirements
- A kubeconfig with appropriate RBAC permissions to perform the desired command.

## TODO
- [ ] Consider additional tasks

