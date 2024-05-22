# Kubernetes FluxCD Reconciliation Errors
This codebundle measures the number of reconciliation errors in the fluxcd controllers and can generate a report of them.

## TaskSet
This taskset generates a report containing a summary of logs for each controller and their errors counts, ending with a total error count.

Example configuration: 
```
CONTEXT=sandbox-cluster-1
```

## SLI
The SLI can be used to monitor the overall health of the reconciliation loops for FluxCD and alert developers when a bad manifest has been provided.

## Requirements
- A kubeconfig with `get` permissions to on the objects/namespaces that are involved in the query.

## TODO
- Add additional rbac and kubectl resources and use cases