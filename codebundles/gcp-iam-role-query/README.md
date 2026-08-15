# GCP IAM Role Query

A generic, on-demand query tool for GCP IAM that answers "what roles are assigned to this service account?" and "what roles are granted on this specific GCP service or resource?". Driven purely by runtime variables, so operators can fetch role and access information dynamically without needing a new bundle for each resource.

## Overview

- **Query Roles for a Service Account**: Returns the full set of IAM role bindings attached to a specific service account, including inherited project bindings and the service account's own IAM policy.
- **Query Roles Assigned to a GCP Resource**: Returns the IAM policy and role bindings for a user-supplied GCP resource (e.g. a bucket, service, or project) using a typed resource string that tolerates fully-qualified and short forms.
- **List Roles for a Specific GCP Service**: Queries the IAM bindings on a named GCP service type (e.g. storage, bigquery, run) across the project, filtering by the requested resource kind.
- **Generate IAM Policy Report for a Project**: Produces a consolidated report of all IAM bindings in the project grouped by principal and role for on-demand auditing.

This bundle is intentionally a query-on-demand tool rather than a fixed-resource monitor. All checks are read-only and report IAM bindings to the runbook output; informational issues are raised when a policy cannot be resolved.

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: GCP Project ID that provides the IAM context for all queries.

### Optional Variables

- `SERVICE_ACCOUNT`: Service account email to query role bindings for. Used by the service-account role query task (default: empty).
- `RESOURCE_NAME`: Full or short name of the GCP resource to query IAM for. Empty means project-level iteration (default: empty).
- `SERVICE_TYPE`: GCP service type (e.g. storage, bigquery, run, gke) used with `RESOURCE_NAME` to scope the query (default: empty).

### Secrets

- `gcp_credentials`: GCP service account JSON key used to authenticate with Cloud IAM APIs. Format: JSON service account key file (contains `type`, `project_id`, `private_key_id`, `private_key`, `client_email`, `client_id`, `auth_uri`, `token_uri`).

## Tasks Overview

### Query IAM Roles for Service Account
Returns the roles bound to the specified service account through project-level bindings and its own resource policy. Useful for understanding what a service account can access and who can impersonate it.

### Query IAM Roles Assigned to Resource
Returns the IAM policy for a user-supplied resource such as a storage bucket, project, or Cloud Run service. If no `RESOURCE_NAME` is provided it defaults to the project IAM policy.

### List IAM Roles for GCP Service
Lists resources of a given service type in the project and reports the IAM bindings on each. If `RESOURCE_NAME` is a specific name, it filters to that resource; if empty, a wildcard, or `All`, it iterates over every resource of the type.

### Generate IAM Policy Report for Project
Produces a consolidated, principal-grouped report of every IAM binding in the project for on-demand security auditing.

## Requirements

The service account used for authentication requires the following IAM permissions (read-only):
- `resourcemanager.projects.getIamPolicy`
- `iam.serviceAccounts.getIamPolicy`
- Additional `getIamPolicy` permissions on any typed resources queried (e.g. `storage.buckets.getIamPolicy`, `run.services.getIamPolicy`).

## Platform Tools

- `gcloud` - Google Cloud CLI
- `gsutil` - Cloud Storage CLI (bucket IAM queries)
- `bq` - BigQuery command-line tool (dataset IAM queries)
- `jq` - JSON processor
