# MongoDB Atlas Cluster Health

Operators use this bundle to watch MongoDB Atlas clusters through digest-authenticated HTTPS calls against Atlas Admin API v2. Responses focus on actionable inventory breadcrumbs, transitional automation envelopes, Atlas replica process cues, and short-window workload telemetry that matches escalation expectations from parent issue #107.

## Overview

- **Baseline inventory**: Print provider footprints, tiers, majors, disks, pause toggles, and live `stateName` values for every Atlas cluster honoring optional name filters before deeper debugging.
- **Operational posture**: Correlate transitional automation states plus Atlas-published MongoDB replica `healthStatus` hints (when Atlas returns them) to separate planned maintenance from regressions affecting availability.
- **Workload metrics**: Stretch compact measurement queries across replica processes to compare CONNECTIVITY_PERCENT, NORMALIZED_SYSTEM_CPU_USER, DISK PARTITION data usage vs `diskSizeGB`, and replication lag surrogates (`OPLOG_SLAVE_LAG_MASTER_TIME`) against tunable envelopes.

Discovery templates assume discovered `mongodb_atlas_cluster` resources expose `match_resource.resource.atlas_project_id` (or fallback `project_id`), optional `organization_id`, and canonical names for `CLUSTER_FILTER`. Adjust template paths if workspace metadata varies.

## Configuration

### Required Variables

- `ATLAS_PROJECT_ID`: 24 hexadecimal characters identifying the Atlas project/group for every REST path segment.

### Optional Variables

- `ATLAS_ORG_ID`: Organizational identifier surfaced in inventories for auditors (informational annotations only).
- `CLUSTER_FILTER`: Comma-separated Atlas cluster names; leave blank or unset to iterate every Atlas cluster enumerated for the scoped project API call.
- `CONNECTION_THRESHOLD`: Percent ceiling evaluated when CONNECTIVITY_PERCENT samples exist per process (defaults to `85`).
- `DISK_UTIL_THRESHOLD`: Modeled occupancy percent comparing maximum `DISK_PARTITION_SPACE_USED_DATA` samples with declared `diskSizeGB` totals (defaults to `85`).
- `REPLICATION_LAG_MS_THRESHOLD`: Milliseconds tolerated for `OPLOG_SLAVE_LAG_MASTER_TIME` spikes (defaults to `5000`).
- `CPU_UTIL_THRESHOLD`: Applies to BOTH the deep metric sweep and bundled SLIs for NORMALIZED_SYSTEM_CPU_USER bursts (defaults to `92`).
- `SLI_MAX_MEASUREMENT_PROCESSES`: Bounds how many PRIMARY hosts the SLI script samples during each heartbeat to stay within Atlas rate envelopes (defaults to `8`).
- `ATLAS_API_BASE`: Sovereign/private endpoint overrides (defaults to `https://cloud.mongodb.com/api/atlas/v2`).
- `ATLAS_ACCEPT_HEADER`: API contract header (defaults to `application/vnd.atlas.2025-02-19+json`; rotate when Atlas documents a successor version).
- `ATLAS_METRICS_MEASUREMENT_DELAY_MS`: Millisecond delay between sequential measurement curls for chatty fleets (defaults to `200`; set `0` to disable).
- `ATLAS_PUBLIC_API_KEY` plus `ATLAS_PRIVATE_API_KEY` may replace the bundled secret whenever RunWhen injects raw halves instead of JSON.

### Secrets

- `atlas_api_key_credentials`: JSON pairing `ATLAS_PUBLIC_API_KEY` / `ATLAS_PRIVATE_API_KEY` (or `publicKey` / `privateKey`) emitted by Atlas for digest-authenticated callers. Grant **Project Read Only** scopes at minimum.

## Tasks & Features

### Gather MongoDB Atlas Cluster Inventory for Project `${ATLAS_PROJECT_ID}`

Lists paused clusters plus clusters whose `stateName` drifts outside `IDLE` while unpaused.

### Check MongoDB Atlas Cluster State for Project `${ATLAS_PROJECT_ID}`

Flags paused clusters separately from automation transitions, investigates MongoDB replica `healthStatus` mismatches whenever Atlas returns that field.

### Analyze MongoDB Atlas Cluster Metrics for Project `${ATLAS_PROJECT_ID}`

Aggregates condensed measurement windows respecting operator thresholds; CONNECTION counts fall back to raw scalars without percent semantics when CONNECTIVITY_PERCENT is unavailable—threshold comparisons activate only when percent samples exist.
