# Kubernetes Jenkins Healthcheck

This taskset checks the Kubernetes workloads that jenkins is reliant on in your Kubernetes cluster, and performs some checks against its rest api to determine if there are any stuck jobs, 
which will result in raised issues if any are detected.

## Tasks
`Fetch Events for Unhealthy Jenkins Kubernetes PersistentVolumeClaims`
`List PersistentVolumes in Terminating State`
`List Pods In Jenkins Namespace with Attached Volumes and Related PersistentVolume Details`
`Fetch the Storage Utilization for PVC Mounts In The Jenkins Namespace`
`Fetch Jenkins StatefulSet Logs`
`Get Related Jenkins StatefulSet Events`
`Fetch Jenkins StatefulSet Manifest Details`
`Check Jenkins StatefulSet Replicas`
`Query The Jenkins Kubernetes Workload HTTP Endpoint`
`Query For Stuck Jenkins Jobs`

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `kubectl`: The location service used to interpret shell commands. Default value is `kubectl-service.shared`.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search. Leave it blank to search in all namespaces.
- `STATEFULSET_NAME`: The name of the statefulset running jenkins
- `LABELS`: Optional labels for fine-tuning log and event searches
- `JENKINS_SA_USERNAME`: The jenkins username associated with the API token
- `JENKINS_SA_TOKEN`: The API token used to perform healthcheck API requests against the endpoint

## Notes

Please note that the script requires permissions to execute commands within the Kubernetes cluster, and it may require additional permissions depending on the tasks it performs (for example, fetching storage utilization for PVC mounts requires kubectl exec permissions). Make sure to review the tasks and the required permissions before running the script.

## TODO
- [ ] Add additional complex pipeline checks for various bad pipeline states
- [ ] Add executor checks
- [ ] Add documentation
- [ ] Refine raised issues
