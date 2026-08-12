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

### Optional Variables

- `APIGEE_ORG`: The Apigee organization name. Accepts either the bare name (`my-org`) or the fully qualified form (`organizations/my-org`). If empty, it is discovered from the Apigee org(s) in `GCP_PROJECT_ID` and recorded in the topology dump, which every downstream check then reads. (default: empty)
- `ENVIRONMENTS`: Comma-separated environment names to scope the environment/target/keystore checks, or `All` for every environment in the org. Used to respect management API rate limits on large orgs. (default: `All`)
- `CERT_EXPIRY_WARNING_DAYS`: Days before a keystore alias certificate expires to raise a warning (severity 2). (default: `30`)
- `TARGET_REACHABILITY_TIMEOUT`: Timeout in seconds for the target server host/port reachability probe. (default: `5`)

### Secrets

- `gcp_credentials`: A GCP service account JSON key. Format is the standard GCP service account JSON object (`type`, `project_id`, `private_key`, `client_email`, `token_uri`, ...). The service account needs `roles/apigee.readOnlyAdmin`, `roles/apigee.analyticsViewer`, `roles/monitoring.viewer`, `roles/logging.viewer`, and `compute.networkViewer` for VPC/PSC inspection.

## SLI

**This bundle currently ships runbook-only — there is no SLI.**

Nothing is lost by that: the runbook is a strict superset of what the SLI
scored. Every check the SLI ran is run by a runbook task, and the runbook
additionally covers southbound VPC peering and instance capacity, which the
score never included. The findings are the same; they are reported as issues
rather than reduced to a number.

The scoring model it replaced averaged five dimensions — org/environment state,
instance attachment coverage, environment group attachments, keystore
certificate expiry, and target server configuration — into a 0-1 value. It is
worth reintroducing once that model has been validated against real
organizations over time; a health score is only useful if the weighting has
been shown to track what operators actually treat as an outage, and reducing
five independent failure modes to one mean loses which one fired.

Two constraints any future SLI must keep, both of which caused real defects
here:

- **A run that could not read the topology must not score as healthy.** Score 0
  when discovery fails, and gate every dimension sub-metric on that too, not
  only the aggregate — otherwise anyone alerting on a single dimension still
  sees green during a blind run.
- **A project with no Apigee organization is not unhealthy.** Distinguish a
  positive determination of absence from a failure to determine, and never
  report the latter as the former.

## Topology discovery (Suite Initialization, not a task)

`discover_topology.sh` builds one config dump of the org topology using org-wide
REST endpoints (`organizations/{org}`, `/environments`, `/instances`,
`/envgroups`, per-resource attachments), which every check reads.

It runs in `Suite Initialization` rather than as a task, because it can raise no
finding about Apigee itself — only about its own ability to run. As a task it
also produced a dishonest task list: when discovery failed, all seven checks
still ran, found nothing, and rendered as passed, which is indistinguishable
from a healthy organization. Failing setup means they are not attempted.

Two outcomes are kept distinct:

| Outcome | Result |
|---|---|
| Success | checks run normally |
| Could not determine (auth, permissions, unreachable) | issue raised, **suite fails**, no check attempted |

Because setup guarantees the topology exists, each check treats a **missing**
topology file as an error rather than as an empty environment.

Setup gates on whether an access token can be minted, not on whether
`gcloud auth activate-service-account` succeeded. Those are not the same thing:
a runner can carry a usable ambient identity (workload identity) and still fail
activation, which is why every other GCP bundle here suffixes that call with
`|| true`. Gating on the activation exit code took a whole run down — all seven
tasks NOT RUN — on a runner where gcloud misread the key file as a `.p12`. The
token probe is the assertion worth keeping strict: it is what every downstream
`gcloud` and `curl` call actually depends on, so a run with no identity at all
still cannot report green.

`APIGEE_ORG` is supplied by the SLX, not resolved at run time: the generation
rule gates on `gcp_apigee_organizations`, so the matched resource is the
organization and its name is known at render time. `discover_topology.sh` keeps
a lookup path for direct invocation, which selects the organization by matching
the response's own `projectId` rather than taking the first entry — the list
endpoint is credential-scoped, so the first entry can belong to another project.

There is no "no Apigee here" outcome any more. The rule previously matched every
indexed project, so most SLXs covered projects with no Apigee at all and needed
special handling to avoid reporting them as broken. Gating on the organization
removes the case entirely.

## Tasks Overview

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
