# GCP Apigee Environment and Edge Health

This CodeBundle diagnoses the northbound and southbound edges of a GCP Apigee X organization: organization and environment ACTIVE state, environment-to-instance attachment coverage, environment group attachments and hostname routing, keystore alias certificate expiry (both northbound hostname TLS and southbound target TLS), target server reachability, southbound VPC peering / Private Service Connect connectivity, and instance capacity / regional failover. It is built first in the Apigee bundle family because attachment gaps and certificate expiry are the highest-severity, lowest-effort wins.

## Overview

The bundle discovers the full Apigee org topology once and then iterates over environments, environment groups, instances, keystores and target servers:

- **Discovery**: Builds one config dump of the org topology (org, environments, instances, env groups, instance attachments, env group attachments) used as input to all other checks.
- **Org/Environment state**: Flags the org and any environment not in ACTIVE state, since a non-serving environment is a total outage for its attached hostnames.
- **Instance attachment coverage**: Flags environments attached to zero runtime instances.
- **Environment group attachments & hostname routing**: Flags groups with no attached environment and hostnames that aren't routed (edge-level 404s).
- **Keystore certificate expiry**: Flags keystore/truststore alias certificates expired or expiring within `CERT_EXPIRY_WARNING_DAYS`, covering both northbound and southbound TLS.
- **Target server configuration & reachability**: Flags disabled target servers and dangling/ unreachable targets.
- **Southbound VPC peering & Private Service Connect**: Flags failed PSC endpoints and exhausted service peering ranges.
- **Instance capacity & regional failover**: Flags non-ACTIVE/reduced-capacity instances and reports single-region environments (no failover).

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: The GCP project that owns the Apigee organization (used for gcloud auth, service peering and Private Service Connect network checks).
- `APIGEE_ORG`: The Apigee organization name (`organizations/{org}`). If empty, it is resolved by discovering the Apigee org(s) in `GCP_PROJECT_ID`.

### Optional Variables

- `ENVIRONMENTS`: Comma-separated environment names to scope the environment/target/keystore checks, or `All` for every environment in the org. Used to respect management API rate limits on large orgs. (default: `All`)
- `CERT_EXPIRY_WARNING_DAYS`: Days before a keystore alias certificate expires to raise a warning (severity 2). (default: `30`)
- `TARGET_REACHABILITY_TIMEOUT`: Timeout in seconds for the target server host/port reachability probe. (default: `5`)

### Secrets

- `gcp_credentials`: A GCP service account JSON key. Format is the standard GCP service account JSON object (`type`, `project_id`, `private_key`, `client_email`, `token_uri`, ...). The service account needs `roles/apigee.readOnlyAdmin`, `roles/apigee.analyticsViewer`, `roles/monitoring.viewer`, `roles/logging.viewer`, and `compute.networkViewer` for VPC/PSC inspection.

## SLI

The SLI produces a continuous 0-1 health score, averaged across five dimensions (each pushed as a sub-metric):

- `org_env_state` — 1.0 if the org and all environments are ACTIVE, else 0.0
- `instance_attachment` — 1.0 if every environment has at least one instance attachment, else 0.0
- `envgroup_attachment` — 1.0 if every environment group has an attachment and routed hostnames, else 0.0
- `keystore_cert` — 1.0 if no keystore/truststore alias certificate expires within `CERT_EXPIRY_WARNING_DAYS`, else 0.0
- `target_server` — 1.0 if all target servers are enabled and reachable, else 0.0

The aggregate is the arithmetic mean of the five dimension scores.

## Tasks Overview

### Discover Apigee Organization, Environments, Instances and Env Groups
Builds one config dump of the org topology using org-wide REST endpoints (`organizations/{org}`, `/environments`, `/instances`, `/envgroups`, per-resource attachments). Serves as the input for all downstream tasks.

### Check Apigee Organization and Environment State
Flags the organization if not ACTIVE, and every environment not in a healthy ACTIVE state or stuck in CREATING/UPDATING/FAILED. A non-serving environment is a total outage.

### Check Apigee Environment to Instance Attachment Coverage
Verifies each environment is attached to at least one runtime instance. Flags environments with zero attachments, which means nothing routes or serves them.

### Check Apigee Environment Group Attachments and Hostname Routing
Verifies each environment group has at least one attachment and routed hostnames. Flags groups with no attached environment and unrouted hostnames, which produce edge-level 404s.

### Check Apigee Keystore Alias Certificate Expiry
Inspects every keystore/truststore alias certificate for attached environments and flags expired or expiring certificates within `CERT_EXPIRY_WARNING_DAYS`. Covers both northbound hostname TLS and southbound target TLS.

### Check Apigee Target Server Configuration and Reachability
For each target server per environment, verifies it is enabled and that its host resolves and port is reachable. Flags disabled and dangling/unreachable targets, which break every call routed to them.

### Check Apigee Southbound VPC Peering and Private Service Connect
Inspects the org network configuration, VPC peering connections and Private Service Connect endpoints/attachments. Flags failed PSC endpoints and exhausted service peering ranges.

### Check Apigee Instance Capacity and Regional Failover
Flags runtime instances that are not ACTIVE or in reduced capacity, and reports environments served by only a single region/instance (no failover) for resilience awareness.

## Requirements

The following IAM permissions are expected on the service account (commonly granted via `roles/apigee.readOnlyAdmin` plus compute/serviceusage viewer roles):

- `apigee.organizations.get`, `apigee.organizations.list`
- `apigee.environments.get`, `apigee.environments.list`
- `apigee.instances.get`, `apigee.instances.list`, `apigee.instances.attachments.list`
- `apigee.envgroups.get`, `apigee.envgroups.list`, `apigee.envgroups.attachments.list`
- `apigee.keystorealises.get`, `apigee.keystorealises.list`, `apigee.keystores.list`
- `apigee.targetservers.get`, `apigee.targetservers.list`
- `compute.forwardingRules.list`, `compute.addresses.list` (PSC / peering inspection)
- `serviceusage.services.list`, `servicenetworking.services.get` (VPC peering)

The `gcloud`, `curl`, `jq`, and `getent` CLI tools are required at runtime. The Apigee (`apigee.googleapis.com`), Service Networking and Compute Engine APIs must be enabled for the project. Note that the `gcloud apigee` command group does NOT cover envgroups, attachments, instances, target servers, keystores/aliases or stats, so this bundle uses the Apigee Management REST API directly through the shared `apigee_common.sh` helper.
