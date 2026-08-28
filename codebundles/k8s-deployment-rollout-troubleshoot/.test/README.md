# Test Infrastructure for k8s-deployment-rollout-troubleshoot

Apply manifests with `task build-infra` to create test deployments covering rollout troubleshoot scenarios in the `test-rollout-troubleshoot` namespace.

## Scenarios

| Deployment | Scenario |
|---|---|
| `healthy-rollout` | Complete healthy rollout |
| `progress-deadline-fail` | ProgressDeadlineExceeded via failing readiness probe |
| `pdb-blocked-rollout` | PDB minAvailable blocks eviction during rollout |
| `image-pull-fail` | ImagePullBackOff on bad image tag |
| `stuck-terminating-seed` | Long preStop hook for terminating pod testing |

Run `task default` after committing and pushing changes to validate generation rules via RunWhen Local discovery.
