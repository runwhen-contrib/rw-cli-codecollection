# K8s Cluster Resource Health

## SLI
The Service Level Indicator will count the amount of nodes that are over 90% active utilization according to `kubectl top nodes`

## TaskSet 
### Identify High Utilization Nodes for Cluster
Create a report of all nodes that are above 90% utilization. Raise issues for each node that is in this state. 

### Identify Pods Causing High Node Utilization in Cluster
This task identifies overutilized nodes and creates a report of each pod that is using more than it's defined request. Since requests are what a cluster autoscaler uses to make decisions, this list should be used to increase the pod requests so that autoscalers can make better scaling decisions. 

Raises an issue for each namespace


## Requirements
- Service account with permissions to: 
    - get nodes
    - list nodes
    - get/list nodes in api group "metrics.k8s.io"