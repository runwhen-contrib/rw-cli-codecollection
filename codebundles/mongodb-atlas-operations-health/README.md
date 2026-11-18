# MongoDB Atlas Operations Health

This CodeBundle performs read-only checks against the MongoDB Atlas Admin API for a single project: live alert posture, whether dedicated clusters report cloud backup enabled, and whether the project IP access list shows risky openness or inconsistencies with public cluster DNS names.

## Overview

- **Alert posture**: Surfaces OPEN and TRACKING alerts (and CLOSED items whose timestamps fall inside `ALERT_LOOKBACK_HOURS` when date parsing works), scoped by optional `CLUSTER_FILTER`, with a short blast-radius summary.
- **Backup coverage**: For `REPLICA_SET`, `SHARDED`, and `GEOSHARDED` clusters, validates `backupEnabled` / `providerBackupEnabled` and records when the cloud backup schedule endpoint is unavailable on lower tiers (downgraded context instead of hard failure).
- **Network access**: Flags `0.0.0.0/0`, very broad `0.0.0.0/N` prefixes, and an empty allowlist when in-scope clusters still publish `connectionStrings.standardSrv` hostnames.
- **SLI**: Averages three binary dimensions into a 0–1 operations health score for periodic monitoring.

API reference: [Atlas Admin API v2](https://www.mongodb.com/docs/api/doc/atlas-admin-api-v2/).

## Configuration

### Required variables

- `ATLAS_PROJECT_ID`: 24-hex MongoDB Atlas project (group) id used in `/groups/{groupId}/...` paths.

### Optional variables

- `ATLAS_ORG_ID`: Organization id for workspace context (reserved for future org-level checks).
- `CLUSTER_FILTER`: Comma-separated Atlas cluster names to limit alert, backup, and network correlation (default: empty, meaning all clusters in the project).
- `ALERT_LOOKBACK_HOURS`: Hours of history for treating recently CLOSED alerts as relevant in the deep-dive runbook task (default: `24`).

### Secrets

- `atlas_api_key_credentials`: Programmatic API key material — preferred shape is JSON `{"ATLAS_PUBLIC_API_KEY":"...","ATLAS_PRIVATE_API_KEY":"..."}` (aliases `publicKey` / `privateKey` are also accepted). Plain multi-line `KEY=value` text works as well. The RunWhen platform injects this for digest authentication to `https://cloud.mongodb.com/api/atlas/v2`.

## Tasks overview

### Check MongoDB Atlas Open Alerts for Project

Paginates `GET /groups/{groupId}/alerts`, applies the cluster scope filter, evaluates OPEN/TRACKING and recent CLOSED signals, and raises a consolidated issue when anything relevant is found.

### Verify MongoDB Atlas Backup Configuration for Project

Lists clusters, checks backup flags on dedicated layouts, and probes `GET .../backup/schedule` for extra context when the tier supports it.

### Review MongoDB Atlas Network Access for Project

Reads `GET /groups/{groupId}/accessList`, warns on open CIDR patterns, and combines cluster connection string hints to detect empty allowlists paired with public SRV endpoints.

### SLI (sli.robot)

Runs lightweight variants of the three checks and publishes sub-metrics `atlas_alerts_clear`, `atlas_backup_ok`, and `atlas_network_ok` plus the aggregate health score.
