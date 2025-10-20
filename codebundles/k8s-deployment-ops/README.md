# Kubernetes Deployment Operations

This codebundle provides a suite of operational tasks related to a deployment in Kubernetes clusters.

## Tasks
- Restart Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
- Force Delete Pods in Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
- Rollback Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}` to Previous Version
- Scale Down Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
- Scale Up Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}` by ${SCALE_UP_FACTOR}x
- Clean Up Stale ReplicaSets for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
- Scale Down Stale ReplicaSets for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`
- **Scale Up HPA for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}` by ${HPA_SCALE_FACTOR}x**
- **Scale Down HPA for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}` to Min ${HPA_MIN_REPLICAS}**
- **Increase CPU Resources for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`**
- **Increase Memory Resources for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`**
- **Decrease CPU Resources for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`**
- **Decrease Memory Resources for Deployment `${DEPLOYMENT_NAME}` in Namespace `${NAMESPACE}`**

### HPA Scaling Tasks
The HPA scaling tasks allow you to scale HorizontalPodAutoscaler min/max replicas:
- **Scale Up HPA**: Multiplies current min/max replicas by `${HPA_SCALE_FACTOR}` (default: 2x)
  - Caps max replicas at `${HPA_MAX_REPLICAS}` to prevent excessive scaling
  - Useful during traffic spikes or capacity planning
- **Scale Down HPA**: Sets both min and max replicas to `${HPA_MIN_REPLICAS}` (default: 1)
  - Useful for reducing resource usage during maintenance or off-peak hours
  - Effectively constrains autoscaling to a minimal level

**GitOps Integration**: Both HPA scaling tasks check for GitOps management (Flux/ArgoCD labels and annotations). If an HPA is managed by GitOps, the tasks will only provide suggestions and not apply changes directly, with instructions to update the HPA manifest in your Git repository.

### Resource Update Tasks

#### Increase Resources
The resource increase tasks intelligently scale up CPU and memory resources based on:
- **VPA Recommendations**: If a VerticalPodAutoscaler exists with recommendations, uses the upper bound value
- **Default Behavior**: If no VPA exists, doubles the current resource request/limit
- **GitOps-Managed Deployments**: Only provides suggestions (does not apply changes) if the deployment has GitOps annotations (Flux, ArgoCD)
- **HPA Considerations**: Does not apply changes if HorizontalPodAutoscaler exists (only provides suggestions) to avoid conflicts

#### Decrease Resources
The resource decrease tasks help optimize costs by reducing over-provisioned resources:
- **Scale Down Factor**: Divides current CPU/memory requests and limits by `${RESOURCE_SCALE_DOWN_FACTOR}` (default: 2, meaning divide by 2)
- **Safety Minimums**: Sets minimum thresholds (10m for CPU, 16Mi for memory) to prevent too-low values
- **GitOps-Managed Deployments**: Only provides suggestions (does not apply changes) if the deployment has GitOps annotations (Flux, ArgoCD)
- **HPA Considerations**: Does not apply changes if HorizontalPodAutoscaler exists (only provides suggestions) to avoid conflicts
- **Use Cases**: Cost optimization, over-provisioned workloads, maintenance windows


## Configuration
The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search. Leave it blank to search in all namespaces.
- `DEPLOYMENT_NAME`: The name of the deployment.
- `SCALE_UP_FACTOR`: A multiple in which to increase deployment replicas by (default: 2)
- `MAX_REPLICAS`: Maximum replicas allowed for deployment scale up operations (default: 10)
- `ALLOW_SCALE_TO_ZERO`: Permit deployments to scale to 0 (default: false)
- `HPA_SCALE_FACTOR`: Multiple by which to scale HPA min/max replicas (default: 2)
- `HPA_MAX_REPLICAS`: Maximum replicas allowed for HPA max value during scale up (default: 20)
- `HPA_MIN_REPLICAS`: Minimum replicas to set for HPA during scale down (default: 1)
- `RESOURCE_SCALE_DOWN_FACTOR`: Factor by which to divide CPU/memory resources when scaling down (default: 2)
## Requirements
- A kubeconfig with appropriate RBAC permissions to perform the desired command.

## TODO
- [ ] Add additional documentation.

