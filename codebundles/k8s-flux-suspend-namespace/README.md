# Kubernetes Flux Suspend Namespace

This codebundle can flux suspend or unsuspend an entire namespace of objects being managed by flux.

## Tasks
`Flux Suspend Namespace`
`Unsuspend Flux for Namespace`

## Configuration
The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `KUBECONFIG`: The kubeconfig secret containing access info for the cluster.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search. Leave it blank to search in all namespaces.


## Requirements
- A kubeconfig with appropriate RBAC permissions to perform the desired command.

## TODO
- [ ] Add additional documentation.
- [ ] Add suspend support for other flux CRDs

