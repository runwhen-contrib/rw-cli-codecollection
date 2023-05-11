# Kubernetes Storage Troubleshooting TaskSet

This taskset provides a set of commands to troubleshoot storage-related issues in a Kubernetes cluster. It leverages the `kubectl` command-line tool to interact with the cluster and retrieve relevant information about persistent volume claims (PVCs), persistent volumes (PVs), and associated events.


## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The path to the Kubernetes kubeconfig YAML file containing connection configuration used to connect to cluster(s).
- `kubectl`: The location service used to interpret shell commands. Default value is `kubectl-service.shared`.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search. Leave it blank to search in all namespaces.

## TaskSet

The TaskSet provides the following tasks:

- `Fetch Events for Unhealthy Kubernetes Persistent Volume Claims`: This task lists events related to persistent volume claims within the desired namespace that are not bound to a persistent volume. It retrieves the events and displays information like the last timestamp, name, and message associated with the PVC.
- `List Persistent Volumes in Terminating State`: This tasl lists events related to persistent volumes in a Terminating state. It retrieves the events and displays information like the last timestamp, name, and message associated with the PV.
- `List Pods with Attached Volumes and Related PV Details`: This task collects details on the configured persistent volume claim, persistent volume, and node for each pod in the specified namespace. It displays information such as the pod name, PVC name, PV name, status, node, zone, ingress class, access modes, and reclaim policy.
- `Fetch the Storage Utilization for PVC Mounts`: This keyword retrieves the storage utilization for PVC mounts in each pod within the specified namespace. It executes the `df -h` command inside each pod and displays information about the pod, PVC, volume name, container name, and mount path. It also checks if the PVC utilization exceeds 95% and raises an issue if it does.

## Pre-requisites

Before running the runbook, ensure you have the following (for local use):

- Access to the Kubernetes cluster
- Permissions to: 
    - List/Get PersistentVolumeClaims, PersistentVolumes, Nodes, Events
    - Execute on pods

Example Kubernetes Role: 
- The following kubernetes role is provided as an example only, and should be modified to suit your environment: 
```
# Role definition (role.yaml)
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: storage-troubleshooting-role
  namespace: <namespace>
rules:
  - apiGroups: [""]
    resources: ["persistentvolumeclaims", "events"]
    verbs: ["list"]
  - apiGroups: [""]
    resources: ["persistentvolumes"]
    verbs: ["list"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["list", "get"]

# RoleBinding definition (rolebinding.yaml)
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: storage-troubleshooting-rolebinding
  namespace: <namespace>
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: storage-troubleshooting-role
subjects:
  - kind: User
    name: <username>  # Replace with the actual username or service account name

```

