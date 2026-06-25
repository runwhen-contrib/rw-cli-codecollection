# SeaweedFS Healthcheck Test Infrastructure

Terraform in this directory deploys the official SeaweedFS Helm chart into `test-seaweedfs-health` with minimal replicas and `emptyDir` storage suitable for Kind or minikube CI validation.

## Prerequisites

- Existing Kubernetes cluster (Kind recommended)
- `terraform`, `helm`, `kubectl`, `task`

## Usage

```bash
cd .test
task build-infra
# Run bundle scripts manually against outputs from terraform output
task clean
```

Adjust `terraform/terraform.tfvars` for your kube context before applying.
