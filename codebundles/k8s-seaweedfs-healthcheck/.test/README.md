# SeaweedFS Healthcheck — `.test` discovery

Two modes:

| Task | Use when |
|---|---|
| `task` / `task discover-live` | SeaweedFS already exists on a shared cluster (e.g. `runwhen-env-test`) |
| `task discover-ci` | Spin up isolated SeaweedFS via Terraform (Kind / CI) |
| `task validate-generation-rules` | Schema-check generation rules only |

## Live cluster discovery (recommended here)

RunWhen Local reads your kubeconfig, scans **one namespace** for SeaweedFS master StatefulSets, and writes SLX/SLI/runbook YAML under `output/`.

```bash
cd codecollection/codebundles/k8s-seaweedfs-healthcheck/.test

export RW_FROM_FILE='{"kubeconfig":"/home/runwhen/auth/shared-kubeconfig"}'
export TEST_NAMESPACE='runwhen-env-test'   # namespace with SeaweedFS master STS
export RW_WORKSPACE='seaweedfs-dev'      # output folder name

task discover-live
# or simply: task
```

Review generated SLXs:

```bash
ls output/workspaces/seaweedfs-dev/slxs/
```

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `RW_FROM_FILE` | — | JSON with `kubeconfig` path (same as `ro` dev mode) |
| `KUBECONFIG` | — | Alternative kubeconfig path |
| `KUBECONFIG_PATH` | `/home/runwhen/auth/shared-kubeconfig` | Fallback path |
| `TEST_NAMESPACE` | `runwhen-env-test` | Namespace scoped to `detailed` LOD |
| `RW_WORKSPACE` | `seaweedfs-dev` | Workspace name in output tree |

You can also drop a file named `kubeconfig.secret` in this directory and skip `prepare-kubeconfig`.

### Important: discovery uses the remote git branch

RunWhen Local **clones your codecollection repo from GitHub**, not the local working tree. Generation-rule or template changes only appear in discovery after you **commit and push** the branch referenced in `workspaceInfo.yaml`.

For quick script/robot iteration without discovery, use `ro` in the bundle root instead.

## Terraform test infra (CI / isolated cluster)

```bash
cd .test
# edit terraform/terraform.tfvars for your kube context
task build-infra
task discover-ci
task clean   # destroys Terraform release + discovery output
```

## Cleanup

```bash
task clean-rwl-discovery   # output/, workspaceInfo.yaml, kubeconfig.secret only
task clean               # also runs terraform destroy when state exists
```
