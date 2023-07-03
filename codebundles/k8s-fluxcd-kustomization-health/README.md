# Kubernetes FluxCD Kustomization Health
The `k8s-fluxcd-kustomizations-health` codebundle checks for Kustomization resources within the Kubernetes cluster to surface up potential issues. 

## TaskSet
This TaskSet looks for any FluxCD managed Kustomizations in the specified namespace within the configured context and: 
- prints a list of every Kustomization and it's status
- prints a list of all kustomizations that are not ready and associated reasons

Example configuration: 
```
DISTRIBUTION=Kubernetes
CONTEXT=sandbox-cluster-1
NAMESPACE=flux-system
RESOURCE_NAME=kustomizations
```

With the example above, the TaskSet will collect the above mentioned data from the specified namespace in the `sandbox-cluster-1` cluster for the resources with a shortname of `kustomizations`. 


## Requirements
- A kubeconfig with `get` permissions to on the objects/namespaces that are involved in the query.


## TODO
- Add additional tasks
- Add additional rbac and kubectl resources and use cases
- Add an SLI for measuing Kustomization health via kubectl (as a prometheus codebundle exists already)
- Add additional troubleshooting tasks as use cases evolve