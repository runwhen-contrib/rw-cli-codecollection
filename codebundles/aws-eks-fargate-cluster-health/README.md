# eks-fargate-cluster-health-issue CodeBundle
### Tags:`AWS`, `EKS Fargate`, `Cluster Health`, `Potential Issue`, `Developer Report`, `Investigation Required`, `Cloud Services`, `Incident Triage`, 
## CodeBundle Objective:
This runbook outlines the necessary steps to manage and troubleshoot an EKS Fargate Cluster using the AWS CLI. It provides instructions on how to check the health status of the EKS Fargate Cluster and examine the AWS VPC CNI plugin for potential networking issues. Additionally, it includes guidance on how to debug the EKS Fargate Pod Execution Role. This runbook is an essential guide for maintaining the smooth operation of EKS Fargate Clusters.

## CodeBundle Inputs:

export CLUSTER_NAME="PLACEHOLDER"

export FARGATE_PROFILE="PLACEHOLDER"

export REGION="PLACEHOLDER"

export AWS_REGION="PLACEHOLDER"

export EKS_CLUSTER_NAME="PLACEHOLDER"

export FARGATE_PROFILE_NAME="PLACEHOLDER"

export PROFILE="PLACEHOLDER"

export LOG_GROUP_NAME="PLACEHOLDER"

export START_TIME="PLACEHOLDER"

export END_TIME="PLACEHOLDER"

export FILTER_PATTERN="PLACEHOLDER"


## CodeBundle Tasks:
### `Check EKS Fargate Cluster Health Status using aws CLI`
#### Tags:`EKS`, `Fargate`, `Cluster Health`, `AWS`, `Kubernetes`, `Pods`, `Nodes`, `Shell Script`, 
### Task Documentation:
This script checks the health status of an Amazon EKS Fargate cluster. It describes the Fargate profile, checks the status of all nodes and pods, and provides detailed information about each pod. The script requires the user to specify the cluster name, Fargate profile name, and AWS region.
#### Usage Example:
`./check_eks_fargate_cluster_health_status.sh`

### `Examine AWS VPC CNI plugin for EKS Fargate Networking Issues`
#### Tags:`AWS`, `EKS`, `Fargate`, `Bash Script`, `Node Health`, `Pod Status`, `CNI Version`, `Kubernetes`, 
### Task Documentation:
This bash script is designed to monitor the health and status of an Amazon EKS cluster. It fetches information about the Fargate profile, checks the health status of EKS nodes, verifies the status of all pods in all namespaces, and checks the CNI version. The script is intended to be run in an environment where AWS CLI and kubectl are installed and configured.
#### Usage Example:
`./examine_aws_vpc_cni_eks_fargate_networking_issues.sh`
