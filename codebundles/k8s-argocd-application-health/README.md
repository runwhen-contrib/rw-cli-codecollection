# Kubernetes ArgoCD Application Health
This codebundle is used to help measure and troubleshoot the health of an ArgoCD managed application. 

## TaskSet
This taskset collects information and runs general troubleshooting checks against argocd application objects within a namespace.

Example configuration for an application in which the ArgoCD Application object resides in the same namespace as the resources themselves: 
```
export DISTRIBUTION=Kubernetes
export CONTEXT=cluster-1
export APPLICATION=otel-demo
export APPLICATION_TARGET_NAMESPACE=otel-demo
export APPLICATION_APP_NAMESPACE=otel-demo
export ERROR_PATTERN="Quota|Error|Exception"
```

## TODO
- [ ] Try support for list of applications in conjunction with single application
- [ ] Add documentation
- [ ] Add issues
