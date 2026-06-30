# GCP Artifact Registry Governance & Cleanup

Inspect Artifact Registry repositories for stale images, missing cleanup policies, and legacy Container Registry (gcr.io) usage. Identifies configuration gaps that inflate storage spend and recommends cleanup policies so spend tracks current or required artifacts only.

## Overview

- **Repository discovery**: Lists Artifact Registry repositories across configured locations with format and size metadata.
- **Cleanup policy checks**: Verifies Docker/OCI repositories define policies for untagged manifests and aged tags.
- **Stale image detection**: Flags tagged images not updated within `STALE_IMAGE_THRESHOLD_DAYS` (uses update/upload time when last-pull is unavailable).
- **Untagged manifest detection**: Finds dangling manifests older than `UNTAGGED_IMAGE_THRESHOLD_DAYS`.
- **Legacy GCR inventory**: Detects remaining `gcr.io` usage and legacy artifact buckets for migration planning.
- **Storage utilization**: Summarizes image/tag counts and estimated GB per repository.
- **Cleanup recommendations**: Outputs read-only suggested cleanup policy JSON/YAML; does not apply policies.

Non-Docker/OCI repositories receive discovery coverage; Docker-specific governance tasks skip unsupported formats (documented below).

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: GCP project ID containing Artifact Registry repositories.

### Optional Variables

- `ARTIFACT_REGISTRY_LOCATIONS`: Comma-separated locations (for example `us-central1,europe-west1`) or `All` (default: `All`).
- `ARTIFACT_REGISTRY_REPOSITORIES`: Comma-separated repository IDs to scope checks, or `All` (default: `All`).
- `ARTIFACT_REGISTRY_LOCATION`: Single location when generated per-repository SLX (overrides location filter when set).
- `ARTIFACT_REGISTRY_REPOSITORY`: Single repository name when generated per-repository SLX (overrides repository filter when set).
- `STALE_IMAGE_THRESHOLD_DAYS`: Days without pull/update after which a tagged image is stale (default: `90`).
- `UNTAGGED_IMAGE_THRESHOLD_DAYS`: Age threshold for untagged manifests (default: `30`).
- `STORAGE_UTILIZATION_THRESHOLD_GB`: Estimated repository GB that triggers a utilization issue; `0` disables (default: `50`).
- `MIN_TAGS_TO_KEEP`: Minimum tagged versions recommended per package in generated policies (default: `5`).

### Secrets

- `gcp_credentials`: GCP service account JSON with Artifact Registry read access. For legacy GCR inventory also grant `roles/storage.objectViewer` on legacy artifact buckets. Standard fields: `type`, `project_id`, `private_key_id`, `private_key`, `client_email`, `client_id`, `auth_uri`, `token_uri`.

### Platform Setup

Enable APIs on test/production projects:

- `artifactregistry.googleapis.com`
- `containerregistry.googleapis.com` (legacy GCR inventory)

Recommended IAM:

- `roles/artifactregistry.reader` on the project
- `roles/storage.objectViewer` when scanning legacy GCR buckets

## Tasks Overview

### Discover Artifact Registry Repositories in GCP Project

Lists repositories in scope and writes `discovered_repositories.json` for downstream tasks. Raises issues when discovery fails or returns zero repositories unexpectedly.

### Check Cleanup Policy Configuration for Repositories

Evaluates Docker/OCI repositories for cleanup policies covering untagged manifests and aged tags. Severity 2 when no policy exists; severity 3 for partial coverage.

### Identify Stale Container Images

Finds tagged images older than `STALE_IMAGE_THRESHOLD_DAYS`. Uses `updateTime`/`uploadTime` as fallback when last-pull timestamps are unavailable via CLI.

### Identify Untagged Images Consuming Storage

Detects untagged manifests older than `UNTAGGED_IMAGE_THRESHOLD_DAYS` and recommends delete-untagged cleanup rules.

### Detect Legacy Container Registry Usage

Inventories `gcr.io/${GCP_PROJECT_ID}` images and legacy `artifacts.*.appspot.com` buckets. Flags migration risk when legacy usage persists.

### Report Artifact Registry Storage Utilization by Repository

Summarizes image counts, tag counts, and estimated storage GB. Highlights repositories above `STORAGE_UTILIZATION_THRESHOLD_GB`.

### Generate Artifact Registry Cleanup Policy Recommendations

Produces read-only suggested cleanup policy documents in `cleanup_policy_recommendations.json`. Applying policies requires elevated permissions and is out of scope.

## SLI

The in-repo SLI averages four binary dimensions (cleanup policy, stale images, untagged manifests, storage utilization) into a 0–1 governance health score.

## Limitations

- Image last-pull timestamps may be unavailable for all formats; stale detection uses update/upload/create timestamps.
- Large repositories paginate image listing (`IMAGE_LIST_MAX`, default 500) to stay within task duration targets.
- Cleanup policy recommendation output is advisory only.

## Local Testing

See `.test/README.md`. Requires `gcloud`, `jq`, and GCP credentials with Artifact Registry reader access.
