# GCP Apigee Security and Configuration Health

Monitors the security posture and access configuration of an Apigee organization. Flags expiring or misconfigured TLS/keystore aliases, API products with missing or overly permissive quota/rate limits, developer apps with over-scoped or inactive consumer keys, unsecured target servers, and low Apigee security scores so operators can harden the API gateway before a leaked key or expired certificate causes an outage or breach.

## Overview

- **Keystore and TLS Alias Expiry**: Enumerates keystores and certificate aliases per environment, flagging aliases that are expired or will expire within `CERT_EXPIRY_WARNING_DAYS` days.
- **API Product Quota and Rate Limits**: Reviews API products' quota, rate limit, and approval settings, flagging products with no quota, an extreme quota (>= `QUOTA_ABUSE_THRESHOLD`), or auto-approval that weakens access control.
- **Developer App Access Scope**: Reviews developer apps and consumer keys for over-broad scopes, disabled/revoked keys, and keys that pose an access-control risk.
- **Security Score and Incidents**: Queries Apigee security metrics (`security/score`, `security/incident_request_count`, `security/detected_request_count`) via Cloud Monitoring to flag a low security score or detected incidents.
- **Target Server and Virtual Host Configuration**: Reviews target servers for missing or incorrect TLS (`sSLInfo`), flagging plaintext backends.
- **Security Summary**: Aggregates all findings into a consolidated org-level security summary with an overall verdict.

## Configuration

### Required Variables

- `APIGEE_ORG`: Apigee organization name (security/config scope).
- `GCP_PROJECT_ID`: GCP Project ID hosting the Apigee runtime (used for security metric queries).

### Optional Variables

- `CERT_EXPIRY_WARNING_DAYS`: Days before certificate expiry at which a keystore alias is flagged (default: `30`).
- `QUOTA_ABUSE_THRESHOLD`: Quota value (requests/time) at or above which an API product is flagged as excessive (default: `1000000`).
- `SECURITY_SCORE_THRESHOLD`: Minimum acceptable Apigee security score (0-100) before the org is flagged (default: `80`).

### Secrets

- `gcp_credentials`: GCP service account JSON key for authentication. Format: JSON object containing `type`, `project_id`, `private_key_id`, `private_key`, `client_email`, `client_id`, `auth_uri`, `token_uri`. The service account must have read access to Apigee and Cloud Monitoring.

## Tasks Overview

### Check Apigee Keystore and TLS Alias Expiry
Enumerates keystores, truststores, and certificate aliases per environment, flagging aliases whose certificates are expired or expiring within `CERT_EXPIRY_WARNING_DAYS`. Uses the `certsInfo.certInfo[].expiryDate` field on each alias.

### Check Apigee API Product Quota and Rate Limits
Reviews API products for missing quota, extreme quota (>= `QUOTA_ABUSE_THRESHOLD`), and dangerous auto-approval settings.

### Check Apigee Developer App Access Scope
Reviews developer apps and their consumer keys for over-broad/wildcard scopes and revoked (inactive) keys that remain attached to apps, flagging access-control risks.

### Check Apigee Security Score and Incidents
Queries Cloud Monitoring in `GCP_PROJECT_ID` for `apigee.googleapis.com/security/score`, `security/incident_request_count`, and `security/detected_request_count`. Flags a security score below `SECURITY_SCORE_THRESHOLD` or detected security incidents.

### Check Apigee Target Server and Virtual Host Configuration
Reviews target servers per environment for missing or disabled TLS (`sSLInfo.enabled`), flagging plaintext backends. Virtual host enumeration is attempted but note that the Apigee Admin API does not currently expose a public virtual-host list endpoint.

### Generate Apigee Security Summary
Aggregates keystore, quota, app access, security score, and target/vhost findings into a consolidated JSON summary (expiring certs, weak quotas, at-risk apps, overall verdict).

## Requirements

The following GCP IAM roles are required on the service account:
- `roles/apigee.readOnlyAdmin` (read access to Apigee resources)
- `roles/monitoring.viewer` (Cloud Monitoring metric queries)

The Apigee security metrics only populate when Advanced API Security / security assessment is enabled; otherwise the security-score check returns no data and raises no issue.

## Platform Tools

- `gcloud` - Google Cloud CLI (authentication + access token)
- `curl` - REST calls to the Apigee Admin and Cloud Monitoring APIs
- `jq` - JSON processor
- `python3` - Python runtime
