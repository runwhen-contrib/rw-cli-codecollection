# Design: `ovirt-engine-health` CodeBundle

**Date:** 2026-06-03
**Status:** Approved (pending spec review)
**Author:** Prathamesh Lohakare (with Claude)

## Summary

A new RunWhen CodeBundle, `codebundles/ovirt-engine-health/`, that monitors the
health of an oVirt virtualization environment (oVirt / Red Hat Virtualization /
Oracle Linux Virtualization Manager) through the oVirt engine REST API
(`/ovirt-engine/api`).

It follows the existing `jenkins-health` pattern: an SLI that emits a composite
0–1 health score, a runbook (taskset) that raises actionable issues, bash
scripts that call the API with `curl`+`jq` and emit JSON, plus `README.md`,
`.test/`, and `.runwhen/` directories.

## Goals

- One comprehensive bundle covering hosts, VMs, storage domains, clusters, and
  events — not one bundle per resource type.
- Auth via oVirt SSO bearer token.
- Optional CA cert for TLS verification (self-signed engine certs are common).
- SLI (score) and runbook (issues + report) parity, sharing the same checks.

## Non-Goals

- Auto-discovery via a cloud provider resource type (oVirt is a self-hosted
  endpoint with no native RunWhen-discovered resource type — see "Discovery").
- Provisioning a real oVirt environment in CI (too heavy). Tests point at a
  user-supplied engine.
- Mutating/remediating oVirt state (read-only checks only).

## Authentication & TLS

A sourced helper `ovirt_auth.sh`, used by every check script:

1. `POST {OVIRT_ENGINE_URL}/ovirt-engine/sso/oauth/token` with
   `grant_type=password`, `scope=ovirt-app-api`, `username`, `password`
   (form-encoded). Parse `.access_token` from the JSON response with `jq`.
2. Export `OVIRT_TOKEN`. All API calls send headers:
   `Authorization: Bearer ${OVIRT_TOKEN}`, `Accept: application/json`,
   `Version: 4`.
3. If the optional `OVIRT_CA_CERT` secret is provided, write it to a temp file
   (trapped for cleanup) and pass `--cacert <file>` to curl; otherwise rely on
   the system trust store.
4. On token-fetch failure, emit an error JSON (`{"error": "..."}`) and exit
   non-zero so the calling task can surface an engine-reachability issue.

## Checks

Seven checks. Each is one task in **both** `sli.robot` and `runbook.robot`.
The SLI pushes a per-check metric (`sub_name=<check>`, value 0 or 1) and the
runbook raises an issue + writes a report section.

| # | Check | Healthy when | Issue (severity) |
|---|---|---|---|
| 1 | **Engine reachability** | `/api` returns 200 + valid JSON, token obtained | engine unreachable / token fetch fails (sev 1) |
| 2 | **Host status** | all hosts `up` | any host `non_operational`, `connecting`, `error`, `install_failed` (sev 2); `maintenance` reported but not failed |
| 3 | **VM status** | no VMs `paused` or `unknown` | VMs paused (often storage I/O) or `unknown` (sev 2); count above `MAX_PAUSED_VMS` |
| 4 | **Storage domain capacity** | status `active` and free % ≥ `OVIRT_STORAGE_FREE_PCT` | domain `inactive`/`maintenance`, or free % below threshold (sev 2) |
| 5 | **Cluster health** | clusters reachable; no global maintenance / hosts-down condition | cluster has down hosts or is in global maintenance (sev 3) |
| 6 | **Recent critical events** | no `error`/`alert` severity events in `OVIRT_EVENT_LOOKBACK` | error/alert events present in window (sev 3) |
| 7 | **Stale VM snapshots** | no active snapshots older than `OVIRT_SNAPSHOT_MAX_AGE` | snapshots older than threshold (disk-bloat risk) (sev 4) |

### Relevant API endpoints (Version 4)

- `GET /ovirt-engine/api` — reachability
- `GET /ovirt-engine/api/hosts` — host status
- `GET /ovirt-engine/api/vms` — VM status
- `GET /ovirt-engine/api/storagedomains` — capacity/status (`available`, `used`)
- `GET /ovirt-engine/api/clusters` — cluster health
- `GET /ovirt-engine/api/events?search=severity>normal&max=...` — events
- `GET /ovirt-engine/api/vms/{id}/snapshots` (per VM) — snapshots

## Configuration

User Variables / Secrets imported in each robot's `Suite Initialization`:

| Name | Kind | Default | Notes |
|---|---|---|---|
| `OVIRT_ENGINE_URL` | user var | — | e.g. `https://engine.example.com` (no trailing `/ovirt-engine`) |
| `OVIRT_USERNAME` | secret | — | e.g. `admin@internal` or `admin@ovirt@internal` |
| `OVIRT_PASSWORD` | secret | — | engine password |
| `OVIRT_CA_CERT` | secret | (optional) | PEM CA bundle; omitted → system trust store |
| `OVIRT_STORAGE_FREE_PCT` | user var | `10` | min free % per storage domain |
| `OVIRT_EVENT_LOOKBACK` | user var | `1h` | window for critical-event check |
| `OVIRT_SNAPSHOT_MAX_AGE` | user var | `7d` | stale-snapshot threshold |
| `MAX_PAUSED_VMS` | user var | `0` | max paused/unknown VMs considered healthy |
| `OVIRT_ENGINE_NAME` | user var | `ovirt-engine` | display name in task titles/SLX |

## SLI Scoring

Each check sets a global `*_score` (0 or 1) and calls
`RW.Core.Push Metric ${score} sub_name=<check>`. A final
`Generate Health Score` task averages the seven sub-scores and pushes the
composite metric (rounded to 2 decimals), mirroring `jenkins-health/sli.robot`.

## Runbook Behavior

For each check the runbook:
- Runs the same bash script.
- Formats results into a `RW.Core.Add Pre To Report` table (`jq … | column -t`).
- Raises `RW.Core.Add Issue` per affected object with `severity`, `expected`,
  `actual`, `title`, `reproduce_hint`, `details`, and `next_steps`
  (concrete oVirt remediation guidance, e.g. "activate storage domain",
  "investigate host in non-operational state").

## Files

```
codebundles/ovirt-engine-health/
  README.md
  sli.robot
  runbook.robot
  ovirt_auth.sh              # sourced token + curl helper
  check_engine.sh            # check 1 (reachability is largely inline in robot)
  host_status.sh             # check 2
  vm_status.sh               # check 3
  storage_domains.sh         # check 4
  cluster_health.sh          # check 5
  recent_events.sh           # check 6
  stale_snapshots.sh         # check 7
  .runwhen/
    generation-rules/ovirt-engine-health.yaml
    templates/ovirt-engine-health-slx.yaml
    templates/ovirt-engine-health-sli.yaml
    templates/ovirt-engine-health-taskset.yaml
  .test/
    Taskfile.yaml
    README.md
```

## Discovery (`.runwhen/`)

oVirt has no RunWhen-discovered resource type, so a cloud-style generation rule
(matching e.g. an EC2 instance) cannot fire. We provide the SLX / SLI / taskset
**templates** so an SLX can be created via config/manually, and a
generation rule keyed on the workspace config index rather than a cloud
resource match. The README documents that SLX creation is config-driven, not
auto-discovered. This is the honest limitation and is called out explicitly.

## Testing (`.test/`)

Lightweight, no infra provisioning:
- `Taskfile.yaml` with tasks to run `sli.robot` / `runbook.robot` against a
  user-supplied `OVIRT_ENGINE_URL` (env-driven), following the conventions of
  other bundles' Taskfiles.
- `README.md` documenting required env vars and how to point at a real/lab
  oVirt engine (or the upstream `ovirt-engine` appliance) for manual testing.
- No terraform (no cloud infra to provision, unlike `jenkins-health`).

## Error Handling

- Every script guards required env vars and exits with a clear message if unset.
- Robot tasks wrap `json.loads` of script stdout in `TRY/EXCEPT`, defaulting to
  an empty list/dict and logging a `WARN` (matching `jenkins-health`), so a
  single failing check never aborts the whole suite.
- Token-fetch failure surfaces as the sev-1 engine-reachability issue.

## Open Risks

- oVirt API field/state names verified against the v4 REST schema during
  implementation (host states, VM states, storagedomain `available`/`used`).
- Event `search` query syntax (`severity>normal`, date filters) confirmed
  against a live engine or docs during implementation.
