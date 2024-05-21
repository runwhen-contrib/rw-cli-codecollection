# Kubernetes Vault Triage

A taskset which checks the status of a Vault workload in Kubernetes.

## Tasks
`Fetch Vault CSI Driver Logs`
`Get Vault CSI Driver Warning Events`
`Check Vault CSI Driver Replicas`
`Fetch Vault Logs`
`Get Related Vault Events`
`Fetch Vault StatefulSet Manifest Details`
`Fetch Vault DaemonSet Manifest Details`
`Verify Vault Availability`
`Check Vault StatefulSet Replicas`

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `kubectl`: The location service used to interpret shell commands. Default value is `kubectl-service.shared`.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search. Leave it blank to search in all namespaces.
- `LABELS`: Labels used to select vault resources.
- `VAULT_URL`: The url of the vault instance.

## Notes

Please note that the script requires permissions to execute commands within the Kubernetes cluster, and it may require additional permissions depending on the tasks it performs (for example, fetching storage utilization for PVC mounts requires kubectl exec permissions). Make sure to review the tasks and the required permissions before running the script.

## TODO
- [ ] Add documentation
- [ ] Refine raised issues 