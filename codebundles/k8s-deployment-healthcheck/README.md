# Kubernetes Deployment Triage

This codebundle provides a suite of tasks aimed at triaging issues related to a deployment and its replicas in Kubernetes clusters.

## Tasks
`Check Deployment Log For Issues`
`Troubleshoot Deployment Warning Events`
`Get Deployment Workload Details For Report`
`Troubleshoot Deployment Replicas`
`Check For Deployment Event Anomalies`
`Check HPA Health for Deployment`

### HPA Health Check
The HPA (HorizontalPodAutoscaler) health check task validates both configuration and runtime status:

#### Configuration Health Checks
- **MinReplicas=1**: Warns about availability risk with single replica minimum (severity 4)
- **Narrow Scaling Range**: Identifies when max-min < 2, limiting scaling flexibility (severity 4)
- **Missing Resource Requests**: Critical alert when HPA uses resource metrics but deployment lacks requests (severity 2)
- **Aggressive CPU Targets**: Warns about targets < 50% causing over-provisioning (severity 4)
- **Conservative CPU Targets**: Warns about targets > 95% lacking headroom (severity 4)
- **Missing Behavior Config**: Suggests adding scaling behavior for better control (severity 4)

#### Runtime Status Checks
- **No HPA**: Raises informational issue if no HPA is configured (severity 4)
- **At Maximum Replicas**: Warns if HPA is at max capacity and cannot scale further (severity 3)
- **At Minimum Replicas**: Suggests cost optimization if consistently at minimum (severity 4)
- **Missing Metrics**: Alerts if HPA has no metrics configured (severity 2)
- **Scaling Limited**: Reports if HPA scaling is constrained (severity 3)
- **Unable to Scale**: Critical alert if HPA cannot perform scaling operations (severity 2)
- **Healthy**: Informational status when HPA is operating normally (severity 4)

## Configuration
The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `kubectl`: The location service used to interpret shell commands. Default value is `kubectl-service.shared`.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search. Leave it blank to search in all namespaces.
- `DEPLOYMENT_NAME`: The name of the deployment.
- `EXPECTED_AVAILABILITY`: The number of replicas allowed.

## Requirements
- A kubeconfig with appropriate RBAC permissions to perform the desired command.

## TODO
- [ ] Add additional documentation.

