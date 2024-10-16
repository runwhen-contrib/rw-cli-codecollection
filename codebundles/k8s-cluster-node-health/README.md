# K8s Cluster Node Health

## SLI
The Service Level Indicator will generate a score for the health of the nodes in the cluster. This is an aggregate score from the tasks, which currently include: 
- Check for Node Restarts in Cluster

## TaskSet 
### Check for Node Restarts in Cluster 
Create a report of all nodes start/stop/preempts/removals in the cluster. This will generate an information issue since node starts/stops may be routine, but users may want to be aware that they are happening if their pods are temporarily affected. 

## Requirements
- Service account with permissions to: 
    - get nodes
    - list nodes
