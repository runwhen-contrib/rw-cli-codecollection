# Kubernetes Deployment Triage

This codebundle provides a task aimed at finding issues related to a Istio being available for the applications in a Cluster.

## Tasks
`Check Deployments for Istio Sidecar Injection`
`Check Istio Sidecar resources usage`
`Verify Istio Istallation`
`Check Istio Controlplane logs for errors and warnings`
`Check Istio Certificates for the Istio Components`
`Analyze Istio configurations`


## Configuration
The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `kubeconfig`: The kubeconfig secret containing access info for the cluster.
- `KUBERNETES_DISTRIBUTION_BINARY`: Which binary to use for Kubernetes CLI commands. Default value is `kubectl`.
- `CONTEXT`: The Kubernetes context to operate within.
- `CLUSTER`: The Kubernetes cluster to operate within.
- `EXCLUDED_NAMESPACE`: The name of the namespaces to exclude in search. Leave it blank to search in all namespaces.
- `CPU_USAGE_THRESHOLD`: The Threshold for CPU usage for istio sidecars.
- `MEMORY_USAGE_THRESHOLD`: The Threshold for MEMORY usage for istio sidecars.

## Requirements
- A kubeconfig with appropriate RBAC permissions to perform the desired command.

## Infra
- To Create Infra use `task build-infra`

### Post Infra operations
```
aws eks --region us-west-2 update-kubeconfig --name istio-cluster
```

- Create kubeconfig with service account token

```
kubectl -n kube-system create serviceaccount kubeconfig-sa
```

```
kubectl create clusterrolebinding add-on-cluster-admin --clusterrole=view --serviceaccount=kube-system:kubeconfig-sa
```

```
cat <<EOF > kubeconfig-sa-token.yaml
apiVersion: v1
kind: Secret
metadata:
  name: kubeconfig-sa-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: kubeconfig-sa
type: kubernetes.io/service-account-token
EOF
```

```
kubectl apply -f terraform/kubeconfig-sa-token.yaml
```

```
TOKEN=`kubectl -n kube-system get secret kubeconfig-sa-token -o jsonpath='{.data.token}' | base64 --decode`
```

```
kubectl config set-credentials kubeconfig-sa --token=$TOKEN
```

```
kubectl config set-context --current --user=kubeconfig-sa
```

```
kubectl config view --minify --raw
```


### To send request to the app and generate errors 

```
kubectl port-forward svc/productpage 9080:9080
```

```
curl http://localhost:9080/productpage?u=normal
```

