# Kubernetes Image Check

Simple informational report that provides information about images in a namespace. 

## Tasks
- `Check Image Rollover Times In Namespace` - Fetches the list of images in a namespace and shows the last time the container was started and therefore the age of the image pull
- `List Images and Tags for Every Container in Running Pods` - Display the status, image name, image tag, and container name for running pods in the namespace.
- `List Images and Tags for Every Container in Failed Pods` - Display the status, image name, image tag, and container name for failed pods in the namespace.
- `List Image Pull Back-Off Events and Test Path and Tags` - Search events in the last 5 minutes for BackOff events related to image pull issues. Run Skopeo to test if the image path exists and what tags are available.

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `kubectl`: The location service used to interpret shell commands. Default value is `kubectl-service.shared`.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `NAMESPACE`: The name of the namespace to search.

## TODO
- [ ] Add documentation
- [ ] Add github integration with source code vs image comparison
- [ ] Find applicable raise issue use