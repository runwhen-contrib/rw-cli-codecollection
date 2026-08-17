---
name: gcp-apigee-environment-health
kind: skill-template
description: Identify health problems on the northbound and southbound edges of a GCP Apigee X organization (org/env state,... Use when triaging or monitoring GCP, Apigee, Edge workloads with skill template `gc...
runtime:
  runbook: runbook.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, Apigee, Edge]
resource_types: [gcp_resource]
access: read-only
---

# GCP Apigee Environment and Edge Health

## Summary

This CodeBundle diagnoses the northbound and southbound edges of a GCP Apigee X organization: organization and environment ACTIVE state, environment-to-instance attachment coverage, environment group attachments and hostname routing, keystore alias certificate expiry (both northbound hostname TLS and southbound target TLS), target server reachability, southbound VPC peering / Private Service....

See [README.md](README.md) for additional context.

## Tools

### Check Apigee Organization and Environment State in `${APIGEE_ORG}`

Flags the organization if it is not ACTIVE and flags every environment that is not in a healthy ACTIVE state or is stuck in CREATING/UPDATING/FAILED, since a non-serving environment is a total outage for its attached hostnames.

- **Robot task name**: <code>Check Apigee Organization and Environment State in `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_org_env_state.sh`
- **Tags**: `gcloud`, `apigee`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:state`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `org_env_state_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Apigee Environment to Instance Attachment Coverage in `${APIGEE_ORG}`

For each environment, verifies it is attached to at least one runtime instance and flags any environment with zero instance attachments, which means nothing routes or serves it even though the environment itself is configured correctly.

- **Robot task name**: <code>Check Apigee Environment to Instance Attachment Coverage in `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_instance_attachments.sh`
- **Tags**: `gcloud`, `apigee`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:state`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `instance_attachment_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Apigee Environment Group Attachments and Hostname Routing in `${APIGEE_ORG}`

For each environment group, verifies it has at least one attachment and that its hostnames are routed, flagging groups with no attached environment and hostnames that are not routed which produce edge-level 404s for callers.

- **Robot task name**: <code>Check Apigee Environment Group Attachments and Hostname Routing in `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_envgroup_attachments.sh`
- **Tags**: `gcloud`, `apigee`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:state`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `envgroup_attachment_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Apigee Keystore Alias Certificate Expiry in `${APIGEE_ORG}`

For each attached environment's keystores and truststores, inspects every alias certificate (northbound hostname TLS and southbound target TLS) and flags any that are expired or will expire within CERT_EXPIRY_WARNING_DAYS.

- **Robot task name**: <code>Check Apigee Keystore Alias Certificate Expiry in `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_keystore_cert_expiry.sh`
- **Tags**: `gcloud`, `apigee`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `keystore_cert_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Apigee Target Server Configuration and Reachability in `${APIGEE_ORG}`

For each target server per environment, verifies it is enabled and that its referenced host resolves and port is reachable, flagging disabled target servers and dangling targets whose host no longer resolves, which break every call routed to them.

- **Robot task name**: <code>Check Apigee Target Server Configuration and Reachability in `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_target_servers.sh`
- **Tags**: `gcloud`, `apigee`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `target_server_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Apigee Southbound VPC Peering and Private Service Connect in `${APIGEE_ORG}`

Inspects the Apigee org network configuration, VPC peering connections and Private Service Connect endpoints/attachments, flagging failed PSC endpoints and exhausted service peering ranges that break every southbound call while all Apigee resources still report healthy.

- **Robot task name**: <code>Check Apigee Southbound VPC Peering and Private Service Connect in `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_southbound_connectivity.sh`
- **Tags**: `gcloud`, `apigee`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:state`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `southbound_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Apigee Instance Capacity and Regional Failover in `${APIGEE_ORG}`

Flags runtime instances whose state is not ACTIVE or that are in reduced capacity, and reports whether any environment is served by only a single region/instance (no failover) so operators understand their resilience posture.

- **Robot task name**: <code>Check Apigee Instance Capacity and Regional Failover in `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_instance_capacity.sh`
- **Tags**: `gcloud`, `apigee`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:state`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `capacity_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_ID` | string | The GCP project ID that owns the Apigee organization. | — | yes |
| `APIGEE_ORG` | string | The Apigee organization name, either "my-org" or "organizations/my-org". If empty, it is discovered within GCP_PROJECT_ID. | `` | yes |
| `ENVIRONMENTS` | string | Comma-separated environment names to scope environment/target/keystore checks, or 'All' for every environment in the org. | `All` | no |
| `CERT_EXPIRY_WARNING_DAYS` | string | Days before a keystore alias certificate expires to raise a warning (severity 2). | `30` | no |
| `TARGET_REACHABILITY_TIMEOUT` | string | Timeout in seconds for the target server host/port reachability probe. | `5` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account JSON used to authenticate with gcloud and the Apigee Management API. | yes |

## Outputs

- `org_env_state_issues.json`
- `instance_attachment_issues.json`
- `envgroup_attachment_issues.json`
- `keystore_cert_issues.json`
- `target_server_issues.json`
- `southbound_issues.json`
- `capacity_issues.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gcp-apigee-environment-health/runbook.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gcp-apigee-environment-health
export GCP_PROJECT_ID=...
export APIGEE_ORG=...
export ENVIRONMENTS=...
export CERT_EXPIRY_WARNING_DAYS=...
export TARGET_REACHABILITY_TIMEOUT=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/gcp-apigee-environment-health
export GCP_PROJECT_ID=...
export APIGEE_ORG=...
export ENVIRONMENTS=...
bash apigee_common.sh
bash check_envgroup_attachments.sh
bash check_instance_attachments.sh
bash check_instance_capacity.sh
bash check_keystore_cert_expiry.sh
bash check_org_env_state.sh
bash check_southbound_connectivity.sh
bash check_target_servers.sh
bash discover_topology.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `apigee_common.sh` — Bash helper script `apigee_common.sh`.
- `check_envgroup_attachments.sh` — Bash helper script `check_envgroup_attachments.sh`.
- `check_instance_attachments.sh` — Bash helper script `check_instance_attachments.sh`.
- `check_instance_capacity.sh` — Bash helper script `check_instance_capacity.sh`.
- `check_keystore_cert_expiry.sh` — Bash helper script `check_keystore_cert_expiry.sh`.
- `check_org_env_state.sh` — Bash helper script `check_org_env_state.sh`.
- `check_southbound_connectivity.sh` — Bash helper script `check_southbound_connectivity.sh`.
- `check_target_servers.sh` — Bash helper script `check_target_servers.sh`.
- `discover_topology.sh` — Bash helper script `discover_topology.sh`.
