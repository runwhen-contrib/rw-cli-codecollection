# GCP Artifact Registry Governance Test Infrastructure

Terraform provisions three Artifact Registry repositories in a GCP project:

| Repository | Purpose |
|------------|---------|
| `*-healthy-*` | Docker repo with cleanup policies (healthy scenario) |
| `*-nopolicy-*` | Docker repo without cleanup policies (missing policy scenario) |
| `*-maven-*` | Non-Docker repo for discovery-only validation |

## Prerequisites

- Terraform >= 1.5
- GCP project with billing enabled
- Credentials with permissions to enable APIs and create Artifact Registry repositories

## Setup

1. Copy credentials into `tf.secret` (not committed):

```bash
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/sa.json
export TF_VAR_project_id=my-gcp-project
```

2. Update `terraform/terraform.tfvars` with your project ID.

3. Build infrastructure:

```bash
task build-infra
```

4. Validate bundle structure:

```bash
task validate-structure
```

5. Cleanup:

```bash
task clean
```

## Test Scenarios

- **healthy_repository_with_cleanup_policy**: Use the healthy repository; expect zero cleanup-policy issues.
- **missing_cleanup_policy_stale_images**: Use the no-policy repository; expect cleanup policy and recommendation issues.
- **legacy_gcr_only**: Requires a project using legacy GCR without Artifact Registry (manual/project-specific).

Populate stale tags in test repos with `gcloud artifacts docker tags add` after pushing sample images if integration testing image age logic.
