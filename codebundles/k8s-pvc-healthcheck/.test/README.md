# Testing Infrastructure
This is tested against a live Sandbox cluster. The acme namespace has been set up with storage issues, as outlined in the scenario here: https://docs.runwhen.com/public/tutorials/k8s-app-storage.

For quick testing purposes, a simple namespace and manifest has been included in the `kubernetes` folder. 

## Environment Setup
Environment Variables: 

```
# Login with auth provider - only needed if kubeconfig does not have permissions to create test infrastructure
gcloud auth login

# Set Namespace to the one used in the test manifest
namespace=$(yq e 'select(.kind == "Namespace") | .metadata.name' kubernetes/mainfest.yaml -N)


# Set Variables for SLI/TaskSet Testing
export KUBERNETES_DISTRIBUTION_BINARY="kubectl"
export CONTEXT="sandbox-cluster-1"
export NAMESPACE="$namespace"
export RW_FROM_FILE='{"kubeconfig":"/home/runwhen/auth/kubeconfig"}'

# Set RunWhen Platform Test Variables
export RW_PAT=[]
export RW_WORKSPACE=[]
export RW_API_URL=[]
```

## Test Scenarios
Certain test scenarios can be manually involked (or added to the Taskfile as desired)

- Fill up the PVC to 90%
```
kubectl exec deploy/test-deployment -n $namespace -- dd if=/dev/zero of=/data/testfile bs=1M count=900 
```

- Reset to 0%
```
kubectl exec deploy/test-deployment -n $namespace -- rm /data/testfile 
```

- Fill it up to 100% and cause CrashLoopBackoff
```
kubectl exec deploy/test-deployment -n $namespace -- dd if=/dev/zero of=/data/testfile bs=1M count=1024 
```