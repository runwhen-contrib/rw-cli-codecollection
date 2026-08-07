# GCP Cloud SQL Health

Monitors GCP Cloud SQL instance health covering availability status, configuration, public access/SSL exposure, and IAM policy risks. Helps operators detect availability, security, and configuration problems before they impact applications.

## Overview

- **Instance Availability & Status**: Enumerates Cloud SQL instances and flags any instance whose state is not RUNNABLE (maintenance, failed, suspended), with state messages.
- **Instance Configuration**: Dumps each instance's configuration (tier, disk, region, zones, database version, maintenance window, backup settings) and flags risky configuration such as an undersized tier, disabled automated backups, or missing point-in-time recovery.
- **Availability & Access**: Flags instances reachable from the public internet or missing SSL enforcement, exposed authorized networks, and instances with IP/environment issues affecting availability.
- **IAM Policy**: Fetches IAM policies for each instance and flags risky bindings including allUsers/allAuthenticatedUsers access and over-broad roles.

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: GCP Project ID containing the Cloud SQL instances.

### Optional Variables

- `RESOURCES`: Optional comma-separated list of Cloud SQL instance names to scope to. Defaults to `All` (auto-discover all instances in the project).
- `CONFIG_IMPORTANCE_THRESHOLD`: Minimum instance tier vCPU count considered healthy. Instances below this are flagged as undersized (default: `2`).

### Secrets

- `gcp_credentials`: GCP service account JSON key for authentication. Format: JSON object containing `type`, `project_id`, `private_key_id`, `private_key`, `client_email`, `client_id`, `auth_uri`, `token_uri`.

## Tasks Overview

### Check Cloud SQL Instance Status
Enumerates all Cloud SQL instances and flags any instance whose state is not RUNNABLE. Detects instances in maintenance, suspended, or failed states that may be unavailable.

### Fetch Cloud SQL Instance Configurations
Dumps each instance's configuration and flags risky configuration including undersized tiers (below the vCPU threshold), disabled automated backups, and disabled point-in-time recovery.

### Check Cloud SQL Instance Availability and Access
Flags instances exposed to the public internet, missing SSL enforcement, containing wildcard authorized networks (0.0.0.0/0), or lacking a usable IP address that would affect availability.

### Check Cloud SQL IAM Policies
Fetches each instance's IAM policy and flags bindings granting access to allUsers or allAuthenticatedUsers, as well as over-broad roles such as owner, editor, or Cloud SQL Admin.

## Requirements

- The GCP Cloud SQL Admin API must be enabled on the project.
- The service account requires `roles/cloudsql.viewer` (`cloudsql.instances.get`, `cloudsql.instances.list`, `cloudsql.instances.getIamPolicy`).
- The service account also needs permissions to read the Cloud SQL instance IAM policies. To grant IAM bindings, additional roles would be required, but all tasks in this bundle are `read-only`.

## Platform Tools

- `gcloud` - Google Cloud CLI (`gcloud sql`)
- `jq` - JSON processor
