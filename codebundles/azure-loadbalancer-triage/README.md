# Azure LoadBalancer Triage

Queries the activity logs of internal loadbalancers (AKS ingress) objects in Azure and optionally inspects internal AKS ingress objects if available.

## Tasks
`Health Check Internal Azure Load Balancer`

## Configuration
The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `AZ_USERNAME`: Azure service account username secret used to authenticate.
- `AZ_CLIENT_SECRET`: Azure service account client secret used to authenticate.
- `AZ_TENANT`: Azure tenant ID used to authenticate to.
- `AZ_HISTORY_RANGE`: The history range to inspect for incidents in the activity log, in hours. Defaults to 24 hours.

## Requirements
- A kubeconfig with appropriate RBAC permissions to perform the desired command.

## TODO
- [ ] Refine issues raised
- [ ] Look at cross az/kubectl support and if keeping it in this codebundle makes sense
- [ ] Add additional documentation.

