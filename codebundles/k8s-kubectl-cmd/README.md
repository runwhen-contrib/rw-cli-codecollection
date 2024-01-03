# Kubernetes kubectl cmd
A generic codebundle used for running bare kubectl commands in a bash shell. 

## SLI
The command provided must provide a single metric that is pushed to the RunWhen Platform. 

Example: `kubectl get pods -n online-boutique -o json | jq '[.items[]] | length`

## TaskSet
The command has all output added to the report for review during a RunSession. 

Example: `kubectl describe pods -n online-boutique`

## Requirements
- A kubeconfig with appropriate RBAC permissions to perform the desired command.