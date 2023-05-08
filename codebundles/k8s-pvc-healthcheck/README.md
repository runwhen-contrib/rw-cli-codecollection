# Kubernetes Storage Troubleshooting Runbook

This runbook provides a set of Robot Framework keywords to troubleshoot storage-related issues in a Kubernetes cluster. It leverages the `kubectl` command-line tool to interact with the cluster and retrieve relevant information about persistent volume claims (PVCs), persistent volumes (PVs), and associated events.

## Pre-requisites

Before running the runbook, ensure you have the following:

- Access to the Kubernetes cluster
- The `kubectl` command-line tool installed and configured to connect to the desired cluster
- The `jq` command-line tool installed to parse JSON output

## Setup

The runbook requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The path to the Kubernetes kubeconfig YAML file containing connection configuration used to connect to cluster(s).
- `kubectl`: The location service used to interpret shell commands. Default value is `kubectl-service.shared`.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search. Leave it blank to search in all namespaces.

## Keywords

The runbook provides the following keywords to troubleshoot storage issues:

### `Fetch Events for Unhealthy Kubernetes Persistent Volume Claims`

This keyword lists events related to persistent volume claims within the desired namespace that are not bound to a persistent volume. It retrieves the events and displays information like the last timestamp, name, and message associated with the PVC.

### `List Persistent Volumes in Terminating State`

This keyword lists events related to persistent volumes in a Terminating state. It retrieves the events and displays information like the last timestamp, name, and message associated with the PV.

### `List Pods with Attached Volumes and Related PV Details`

This keyword collects details on the configured persistent volume claim, persistent volume, and node for each pod in the specified namespace. It displays information such as the pod name, PVC name, PV name, status, node, zone, ingress class, access modes, and reclaim policy.

### `Fetch the Storage Utilization for PVC Mounts`

This keyword retrieves the storage utilization for PVC mounts in each pod within the specified namespace. It executes the `df -h` command inside each pod and displays information about the pod, PVC, volume name, container name, and mount path. It also checks if the PVC utilization exceeds 95% and raises an issue if it does.

## Execution

To execute the runbook, run the Robot Framework test suite by providing the `runbook.robot` file as input:
```
robot runbook.robot

```

Ensure that you have the necessary permissions to execute the commands within the Kubernetes cluster.

## Troubleshooting

If any issues arise during the execution of the runbook, ensure that you have the proper access and permissions to interact with the Kubernetes cluster using the `kubectl` command-line tool.

For more information on troubleshooting storage-related issues in Kubernetes, refer to the official Kubernetes documentation and resources.

**Note**: The runbook assumes a specific structure and environment. Make sure to adapt it to your specific Kubernetes environment and requirements.

---

This README provides an overview of the Kubernetes Storage Troubleshooting Runbook and its usage. Refer to the individual keywords for detailed information on each troubleshooting task.