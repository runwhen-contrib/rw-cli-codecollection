# Kubernetes Namespace Chaos Engineering

This codebundle provides chaos injection for kubernetes namespaces 

## Tasks

`Test Namespace Highly Available`
`Test Node Drain`
`Mangle Service Selector`
`Mangle Service Port`
`Fill Pod Tmp`

## Configuration
The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `KUBECONFIG`: The kubeconfig secret containing access info for the cluster.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search. Leave it blank to search in all namespaces.


## Requirements
- A kubeconfig with appropriate RBAC permissions to perform the desired command.

## TODO
- [ ] Add additional documentation.

