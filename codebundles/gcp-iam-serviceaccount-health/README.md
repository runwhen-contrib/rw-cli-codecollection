# GCP IAM Service Account Health

Monitors GCP IAM service accounts to detect risk from excessive or privileged role assignments, improper key hygiene (old, many, or un-rotated keys), disabled service accounts still bound to resources, and overly broad IAM bindings across a project.

## Overview

- **Privileged Role Assignments**: Lists service accounts granted owner, editor, or other high-privilege roles at the project or service-account level and flags them for review.
- **Key Rotation**: Detects service account JSON/USER_MANAGED keys older than the configured rotation threshold and warns when rotation is overdue.
- **Excessive Keys**: Flags service accounts holding more than the allowed number of active keys, which broadens the attack surface.
- **Disabled Service Accounts in Use**: Finds disabled service accounts that are still referenced in IAM policy bindings, indicating drift.
- **Service Account IAM Policy Analysis**: Summarizes all service-account-level IAM role bindings in the project for a quick health overview and drift detection (e.g., unused service accounts with no bindings).

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: GCP Project ID that houses the service accounts to inspect.

### Optional Variables

- `SERVICE_ACCOUNT`: Optional email of a single service account to scope checks to. Empty means all service accounts in the project (default: empty).
- `KEY_ROTATION_DAYS`: Maximum allowed age of a service account key in days before rotation is flagged (default: `90`).
- `MAX_KEYS_PER_SA`: Maximum allowed number of active keys per service account before it is flagged (default: `5`).
- `PRIVILEGED_ROLES`: Comma-separated list of roles considered high-privilege and worth flagging (default: `roles/owner,roles/editor`).

### Secrets

- `gcp_credentials`: GCP service account JSON key for authentication. Format: JSON object containing `type`, `project_id`, `private_key_id`, `private_key`, `client_email`, `client_id`, `auth_uri`, `token_uri`. Provided via `GOOGLE_APPLICATION_CREDENTIALS` / gcloud auth activation.

## Tasks Overview

### Check Service Account Privileged Role Assignments
Lists service accounts granted owner, editor, or other high-privilege roles (configured via `PRIVILEGED_ROLES`) at the project or service-account level. Raises issues for each privileged binding found.

### Check Service Account Key Rotation
Detects USER_MANAGED service account keys older than `KEY_ROTATION_DAYS` and warns when rotation is overdue. Raises a warning for stale keys and a higher-severity issue for keys more than twice the rotation threshold.

### Identify Service Accounts with Excessive Keys
Flags service accounts holding more than `MAX_KEYS_PER_SA` active USER_MANAGED keys. Each extra key increases the attack surface and complicates rotation.

### Identify Disabled Service Accounts in Use
Finds disabled service accounts that are still referenced in project-level or service-account-level IAM policy bindings, which can indicate drift.

### Analyze Service Account IAM Policy for Project
Summarizes all service-account-level IAM role bindings and raises a warning for service accounts with no bindings (potential unused/drift), giving a quick health overview of the project.

## SLI

This CodeBundle ships an in-repo `sli.robot` that produces a 0-1 health score by averaging five binary dimensions: privileged role assignments, key rotation, key count, disabled service accounts, and IAM policy health. The SLI is deployed via the `*-sli.yaml` template and runs periodically.

## Requirements

The following GCP IAM roles are required on the service account used for authentication:
- `roles/iam.serviceAccountKeys.list` (list service account keys)
- `roles/iam.serviceAccounts.getIamPolicy` (read service-account-level IAM policies)
- `roles/resourcemanager.projectIamAdmin` or `roles/resourcemanager.organizationViewer` scope to read project-level IAM policies (or `roles/iam.securityReviewer`)

All checks are read-only.

## Platform Tools

- `gcloud` - Google Cloud CLI
- `jq` - JSON processor
- `bash` - Shell runtime
