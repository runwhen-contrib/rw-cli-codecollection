# GCP BigQuery Dataset Health

Monitors BigQuery dataset and table health including size trends, access control configuration, expiration policies, and audit logging. Helps operators identify oversized tables, misconfigured access, and datasets without appropriate retention or audit protections.

## Overview

- **Table Size Trends**: Analyzes table sizes across all datasets, identifies the largest tables exceeding configurable thresholds.
- **Dataset Access Configuration**: Reviews IAM policies on all datasets to detect public access, overly permissive roles, or datasets lacking fine-grained access controls.
- **Table Expiration Policies**: Identifies tables without expiration timestamps and datasets without default table expiration.
- **Audit Logging Configuration**: Verifies that BigQuery audit logs (data access logs) and log sinks are configured.
- **Table Partitioning and Clustering**: Identifies large tables lacking partitioning or clustering for optimization.
- **Dataset Health Summary**: Produces a consolidated dataset health summary including total datasets/tables, total storage, and largest tables.

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: GCP Project ID containing BigQuery resources.

### Optional Variables

- `TABLE_SIZE_THRESHOLD_GB`: Table size in GB above which an issue is raised (default: `100`).
- `TABLE_GROWTH_THRESHOLD_PERCENT`: Month-over-month growth percentage that triggers an alert (default: `50`).
- `INCLUDE_STREAMING_BUFFER`: Whether to include streaming buffer in table size calculations (default: `false`).

### Secrets

- `gcp_credentials`: GCP service account JSON key for authentication. Format: JSON object containing `type`, `project_id`, `private_key_id`, `private_key`, `client_email`, `client_id`, `auth_uri`, `token_uri`.

## Tasks Overview

### Check BigQuery Table Size Trends
Analyzes table sizes across all datasets, identifies the largest tables and their growth trend. Raises issues for tables exceeding a configurable size threshold.

### Check BigQuery Dataset Access Configuration
Reviews IAM policies on all datasets to detect public access, overly permissive roles (allUsers, allAuthenticatedUsers). Raises issues for each misconfigured dataset.

### Check BigQuery Table Expiration Policies
Identifies tables without expiration timestamps and datasets without default table expiration. Raises issues for datasets and tables lacking retention policies.

### Check BigQuery Audit Logging Configuration
Verifies that BigQuery audit logs are enabled in the project. Checks for log sinks that capture BigQuery audit events.

### Analyze BigQuery Table Partitioning and Clustering
Identifies large tables (> 1 GB) that lack partitioning or clustering, indicating potential for optimization and cost savings.

### Generate BigQuery Dataset Health Summary Report
Produces a consolidated dataset health summary including total datasets/tables, total storage, largest tables, and datasets without expiration.

## Requirements

This codebundle authenticates with a GCP service account (`gcp_credentials`, activated via `gcloud auth activate-service-account`; the `bq` CLI inherits the same credentials) scoped to `${GCP_PROJECT_ID}`. It performs read-only metadata operations only (`bq ls` / `bq show`) — it runs **no** queries, so no `bigquery.jobs.create` / data-read permission is needed.

**Granular IAM permissions**
- `bigquery.datasets.get` — `bq ls` (dataset enumeration) and `bq show <dataset>` (reads the `.access` ACL and default expiration)
- `bigquery.tables.list` — `bq ls <dataset>` (enumerate tables)
- `bigquery.tables.get` — `bq show <dataset.table>` (table metadata: size, expiration, partitioning, clustering)
- `resourcemanager.projects.getIamPolicy` — `gcloud projects get-iam-policy` (audit-logging check)
- `logging.sinks.list` — `gcloud logging sinks list` (audit-logging check)

**Suggested predefined role(s)**
- `roles/bigquery.metadataViewer` — covers `bigquery.datasets.get`, `bigquery.tables.list`, `bigquery.tables.get` (metadata only, no row-data access)
- `roles/iam.securityReviewer` — covers `resourcemanager.projects.getIamPolicy`
- `roles/logging.viewer` — covers `logging.sinks.list` (`roles/logging.configViewer` also works)

> Requires the BigQuery (`bigquery.googleapis.com`), Cloud Resource Manager (`cloudresourcemanager.googleapis.com`), and Cloud Logging (`logging.googleapis.com`) APIs enabled on the project.

## Platform Tools

- `gcloud` - Google Cloud CLI
- `bq` - BigQuery command-line tool
- `jq` - JSON processor
- `python3` - Python runtime