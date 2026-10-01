# GCP Project Configuration Audit

Audits a GCP project's configuration for security and operational risks by analyzing Cloud Audit Logs for `PERMISSION_DENIED` events, detecting IAM policy changes over a lookback window, and surfacing org policy constraint violations. Provides operators a consolidated, project-level risk snapshot.

## Overview

- **PERMISSION_DENIED Activity Analysis**: Queries Cloud Logging admin activity logs for `PERMISSION_DENIED` events over the lookback window and flags unusually high volumes or repeated denied actions that indicate misconfiguration, over-permissioning, or API/secret misuse.
- **IAM Policy Change Detection**: Inspects Cloud Audit Logs for `SetIamPolicy` events and reports who granted or revoked roles and on which resources, highlighting privileged-role changes for review.
- **Org Policy Constraint Violations**: Enumerates enforced Organization Policy constraints (boolean and list constraints) and reports violations where project configuration contradicts the constraints, such as public bucket access or disabled service usage.
- **Audit Log Configuration Verification**: Checks that admin activity, data access, and policy denied audit logging modes are enabled and that a log sink or export exists so log-based audit tasks are meaningful.
- **Project Configuration Audit Summary**: Aggregates findings from all tasks into a single consolidated risk summary for the project.

All tasks are read-only and use `gcloud`. The permission-denied and IAM-change tasks rely on Cloud Logging entries; if the project or its sink has no audit logs (audit logging disabled), the verify-audit-log-config task raises a coverage-gap issue and the log-based tasks degrade gracefully to an informational message rather than a hard failure.

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: GCP project ID to audit for configuration risks.

### Optional Variables

- `LOOKBACK_WINDOW`: ISO-8601 duration defining how far back to analyze Cloud Audit Logs (default: `P7D`). Examples: `P7D`, `PT6H`, `P30D`.
- `PERMISSION_DENIED_THRESHOLD`: Minimum number of distinct PERMISSION_DENIED events before an issue of severity 3 is raised (default: `10`).
- `ORG_ID`: Optional parent organization ID used to evaluate inherited org policy constraints (default: empty).

### Secrets

- `gcp_credentials`: GCP service account JSON key for authentication. Format: JSON service account key file (contains `type`, `project_id`, `private_key_id`, `private_key`, `client_email`, `client_id`, `auth_uri`, `token_uri`). Injected via `GOOGLE_APPLICATION_CREDENTIALS`.

## Tasks Overview

### Analyze Cloud Audit Logs for PERMISSION_DENIED Events
Queries Cloud Logging for `PERMISSION_DENIED` events over the lookback window. Raises a severity-3 issue when the volume exceeds `PERMISSION_DENIED_THRESHOLD` and an informational issue whenever denied activity is present.

### Detect IAM Policy Changes
Inspects Cloud Audit Logs for `SetIamPolicy` events. Raises a severity-3 issue when privileged role changes (owner/admin/editor) are detected and an informational issue for any IAM change in the window.

### Analyze Org Policy Constraint Violations
Enumerates effective org policies for the project. Raises issues for boolean constraints that are present but not enforced (e.g. `compute.requireOsLogin`, `iam.disableServiceAccountKeyCreation`) and for `storage.publicAccessPrevention` not being enforced.

### Verify Cloud Audit Log Configuration
Checks the project's audit config (`ADMIN_READ`, `DATA_READ`, `DATA_WRITE`, `POLICY_DENIED`) and log sinks. Raises a coverage-gap issue when audit logging is missing or no sink exists.

### Generate Project Configuration Audit Summary Report
Aggregates all findings into a consolidated risk snapshot for the project.

## Requirements

The following GCP roles/permissions are required on the service account:

- `roles/logging.viewer` (or `logging.logEntries.list`) to read Cloud Logging audit entries
- `resourcemanager.projects.getIamPolicy` to read IAM policy and audit config
- `resourcemanager.projects.getOrgPolicy` and `orgpolicy.policy.get` (or `roles/orgpolicy.policyViewer`) to enumerate org policies
- Cloud Logging API and Cloud Resource Manager API must be enabled

## Platform Tools

- `gcloud` - Google Cloud CLI
- `jq` - JSON processor
