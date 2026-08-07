# GCP Apigee API Proxy Health

This CodeBundle monitors the health of Apigee API proxies and their deployments across all environments in an Apigee organization. It flags undeployed or stale proxies, proxies whose deployed revision trails the latest revision, environments with no active deployments, and inactive runtimes so operators catch broken or missing API deployments before consumers are impacted.

## Overview

The bundle discovers all API proxies and environments in an Apigee organization and analyzes proxy deployment health across four dimensions:

- **Deployment health**: Flags proxies that are not deployed at all, are in an error/pending state, or are running a stale (non-latest) revision
- **Environment deployment coverage**: Flags environments that host traffic but have zero active proxy deployments
- **Revision and approval state**: Flags proxies still in a draft/imported (non-final) state and revisions superseded by a newer version that has not been promoted
- **Runtime status**: Flags environments whose runtime is inactive/unavailable using the `apigee.googleapis.com/environment/active` Cloud Monitoring metric

## Configuration

### Required Variables

- `APIGEE_ORG`: The Apigee organization name hosting the API proxies to check.
- `GCP_PROJECT_ID`: The GCP project ID hosting the Apigee runtime, used for authentication and Cloud Monitoring queries.

### Optional Variables

- `STALE_REVISION_THRESHOLD`: Number of revisions behind latest before a proxy is flagged as stale. (default: `1`)
- `INCLUDE_DRAFT_PROXIES`: Whether to include non-deployed/draft proxies as issues (`true`) or ignore them (`false`). (default: `true`)
- `METRIC_LOOKBACK_PERIOD`: Cloud Monitoring lookback period for runtime metric queries in seconds (e.g., `3600s`, `86400s`). (default: `3600s`)

### Secrets

- `gcp_credentials`: A GCP service account JSON key with `roles/apigee.readOnlyAdmin` (or `roles/apigee.admin`) and `roles/monitoring.viewer`. Format is the standard GCP service account JSON object (containing `type`, `project_id`, `private_key_id`, `private_key`, `client_email`, `client_id`, `auth_uri`, `token_uri`), used to obtain an access token for the Apigee Admin API and Cloud Monitoring.

## SLI

The SLI produces a continuous 0-1 health score, averaged across four dimensions (each pushed as a sub-metric):

- `deployment_health` — 1.0 if no proxies are undeployed or running a stale revision, else 0.0
- `environment_coverage` — 1.0 if every environment has at least one active deployment, else 0.0
- `revision_health` — 1.0 if no proxies are in draft state with un-promoted revisions, else 0.0
- `runtime_health` — 1.0 if all environments report an active runtime, else 0.0

The aggregate is the arithmetic mean of the four dimension scores.

## Tasks Overview

### Discover Apigee API Proxies and Deployments
Lists all API proxies, environments, and the deployment state (current revision, revision state, status) of every proxy revision across environments. Produces the discovery/input dump used by all downstream check tasks.

### Check Apigee Proxy Deployment Health
For each API proxy, verifies the deployed revision matches the latest available revision and that deployments have a state of `deployed`, flagging proxies that are not deployed at all, are in an error/pending state, or are running a stale (non-latest) revision.

### Check Apigee Environment Deployment Coverage
Identifies environments with no deployed proxies. An environment that should host traffic but has zero active deployments is flagged so empty/blind spots in API delivery are caught.

### Check Apigee Proxy Revision and Approval State
Detects proxies still in a draft/imported (non-final) state and revisions superseded by a newer revision that has not been promoted to a deployed environment.

### Check Apigee Runtime Environment Status
Verifies Apigee runtime availability per environment using the `apigee.googleapis.com/environment/active` metric via Cloud Monitoring, flagging environments or instances that are inactive or unavailable.

### Generate Apigee Proxy Health Summary
Aggregates all proxy, deployment, environment, and runtime findings into a consolidated health summary (proxy totals, deployed vs not-deployed, stale revisions, at-risk environments) with an overall verdict.

## Requirements

The following IAM permissions are required on the service account (via a custom role, or `roles/apigee.readOnlyAdmin` + `roles/monitoring.viewer`):

- `apigee.apiproxyrevisions.read`
- `apigee.apiproxydeployments.read`
- `apigee.environments.list`
- `apigee.environments.get`
- `monitoring.timeSeries.list`

The `curl`, `jq`, and `gcloud` CLI tools are required at runtime. The Apigee (apigee.googleapis.com) and Cloud Monitoring (monitoring.googleapis.com) APIs must be enabled for the project. Apigee X is the assumed runtime; classic Edge and hybrid have equivalent management endpoints.

The bundle calls the Apigee Admin API (`https://apigee.googleapis.com/v1/organizations/{org}/...`) with a service-account-derived bearer token, and Cloud Monitoring for the runtime metric in `GCP_PROJECT_ID`. See the [Apigee Admin API reference](https://cloud.google.com/apigee/docs/api-platform/reference/apis).