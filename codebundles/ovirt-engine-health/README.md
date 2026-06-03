# oVirt Engine Health

This CodeBundle monitors and evaluates the health of an oVirt virtualization
environment (oVirt / Red Hat Virtualization / Oracle Linux Virtualization
Manager) using the oVirt engine REST API (`/ovirt-engine/api`).

## SLI
The SLI produces a score of 0 (bad), 1 (good), or a value in between. The score
is the average of the following checks:
- oVirt engine is reachable and an SSO token can be obtained
- No hypervisor hosts in an unhealthy (non-operational) state
- No VMs in a paused / unknown / not-responding state (within `MAX_PAUSED_VMS`)
- All storage domains active and above the free-space threshold
- No clusters with hosts down (non-up, non-maintenance)
- No error/alert severity engine events in the lookback window
- No VM snapshots older than the configured maximum age

## TaskSet (Runbook)
Runs the same checks and raises an actionable issue for each problem found
(unreachable engine, non-operational hosts, paused VMs, low/inactive storage
domains, clusters with down hosts, critical events, and stale snapshots), with
oVirt-specific remediation guidance.

## Authentication
The bundle authenticates with the engine's SSO endpoint
(`/ovirt-engine/sso/oauth/token`, `grant_type=password`,
`scope=ovirt-app-api`) to obtain a bearer token, which is then sent on every
API call.

## Required Configuration

```
export OVIRT_ENGINE_URL="https://engine.example.com"   # no trailing /ovirt-engine
export OVIRT_USERNAME="admin@internal"                  # include the auth profile
export OVIRT_PASSWORD=""
```

Optional:

```
export OVIRT_CA_CERT=""             # PEM CA bundle; omit to use the system trust store
export OVIRT_STORAGE_FREE_PCT="10"  # min free % per storage domain
export OVIRT_EVENT_LOOKBACK="1h"    # window for critical events
export OVIRT_SNAPSHOT_MAX_AGE="7d"  # stale snapshot threshold
export MAX_PAUSED_VMS="0"           # max paused/unknown VMs considered healthy
export OVIRT_ENGINE_NAME="prod-ovirt"
```

> **TLS note:** oVirt engines typically present a self-signed CA. Provide the
> engine CA via `OVIRT_CA_CERT` to verify the connection. If omitted, the
> system trust store is used (the request will fail if the cert is not trusted).

## Discovery
oVirt has no RunWhen-discovered cloud resource type, so SLXs for this bundle are
created from the workspace config index rather than auto-discovered from a cloud
provider. The templates under `.runwhen/templates/` define the SLX, SLI, and
runbook; the generation rule under `.runwhen/generation-rules/` wires them to
the config index. Provide the `OVIRT_ENGINE_URL` config value and the
`OVIRT_USERNAME` / `OVIRT_PASSWORD` (and optional `OVIRT_CA_CERT`) workspace
secrets.

## Testing
See the `.test` directory for how to run the SLI and runbook against a reachable
oVirt engine or lab environment.
