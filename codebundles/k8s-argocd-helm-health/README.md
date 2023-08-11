# Kubernetes ArgoCD Helm Health
This codebundle is used to help measure and troubleshoot the health of an ArgoCD managed Helm deployments. 

## TaskSet
This taskset collects information and runs general troubleshooting checks against argocd Helm applications objects within a namespace.

Example configuration for an application in which the ArgoCD Application object resides in the same namespace as the resources themselves: 
```
export DISTRIBUTION=Kubernetes
export CONTEXT=cluster-1
export NAMESPACE=otel-demo
export RESOURCE_NAME="applications.argoproj.io"
```

## TODO
- [ ] Try support for list of applications in conjunction with single application
- [ ] Add documentation
- [ ] Add issues
