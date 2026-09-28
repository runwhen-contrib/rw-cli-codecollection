# Test infrastructure for vast-k8s-csi-health

Static Kubernetes manifests under `kubernetes/manifest.yaml` create:

- Namespace `test-vast-csi-health`
- StorageClass `vast-test-sc` with provisioner `csi.vastdata.com`
- PVC and Deployment referencing VAST storage

## Usage

```bash
task build-infra          # kubectl apply manifests
task validate-generation-rules
task default              # requires pushed commits + RunWhen Local
task clean
```

The PVC will remain Pending without a real VAST CSI driver; generation rules still match the StorageClass name and annotations for SLX discovery testing.
