# Testing Infrastructure
This is tested against a live Sandbox cluster. The acme namespace has been set up with storage issues, as outlined in the scenario here: https://docs.runwhen.com/public/tutorials/k8s-app-storage. The repository with K8s manifests can be found here: https://github.com/runwhen-contrib/demo-sandbox-acme-fitness

## Environment Setup
Environment Variables: 

```
gcloud auth login

export KUBERNETES_DISTRIBUTION_BINARY="kubectl"
export CONTEXT="sandbox-cluster-1"
export NAMESPACE="test-fill-volume"
export RW_FROM_FILE='{"kubeconfig":"/home/runwhen/auth/kubeconfig"}'
export KUBECONFIG="/home/runwhen/auth/kubeconfig"
```