# Kubernetes Ingress Healthcheck
The `k8s-ingress-healthchech` codebundle checks the health of ingress objects within a Namespace. 

## Tasks
`Fetch Ingress Object Health in Namespace` - This command will list every ingress object and determine whether it has a service and and endpoint. If so, it is considered healthy. It will print out the health result along with the error or the details regarding the service name and pod endpoint names and IPs. 

Example configuration: 
```
KUBERNETES_DISTRIBUTION_BINARY=kubectl
CONTEXT=sandbox-cluster-1
NAMESPACE=my-namespace
```

## Requirements
- A kubeconfig with `get` permissions to on the objects/namespaces that are involved in the query.


## TODO
- Add additional rbac and kubectl resources and use cases
- Add additional troubleshooting tasks as use cases evolve