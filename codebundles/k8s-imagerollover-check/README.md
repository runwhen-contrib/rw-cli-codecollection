# Kubernetes Image Rollover Check

Simple informational triage report that fetches the list of images in a namespace and shows the last time the container was started and therefore the age of the image pull.
## Tasks
`Check Image Rollover Times In Namespace`

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `kubectl`: The location service used to interpret shell commands. Default value is `kubectl-service.shared`.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search.

## Notes

Please note that the script requires permissions to execute commands within the Kubernetes cluster, and it may require additional permissions depending on the tasks it performs (for example, fetching storage utilization for PVC mounts requires kubectl exec permissions). Make sure to review the tasks and the required permissions before running the script.

## TODO
- [ ] Add documentation
- [ ] Add github integration with source code vs image comparison
- [ ] Find applicable raise issue use