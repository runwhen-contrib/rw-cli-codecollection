# Mock oVirt engine

A dependency-free (Python stdlib only) mock of the oVirt engine REST API,
serving just the endpoints `ovirt-engine-health` calls. Use it to exercise the
full bundle flow — SSO token → bearer auth → JSON parsing → scoring → issue
raising — without a real engine.

## What it serves

| Endpoint | Returns |
|---|---|
| `POST /ovirt-engine/sso/oauth/token` | a static bearer token |
| `GET /ovirt-engine/api` | product_info + summary |
| `GET /ovirt-engine/api/hosts` | host list |
| `GET /ovirt-engine/api/vms` | VM list |
| `GET /ovirt-engine/api/storagedomains` | storage domains |
| `GET /ovirt-engine/api/clusters` | clusters |
| `GET /ovirt-engine/api/events` | error/alert events + a warning (client filters it) |
| `GET /ovirt-engine/api/vms/<id>/snapshots` | snapshots (active + optionally stale) |

Event times and snapshot dates are generated relative to "now", so the bundle's
lookback/age windows behave realistically.

## Scenarios

Set `MOCK_SCENARIO`:
- **`unhealthy`** (default) — a non-operational host, a paused VM, a near-full
  data domain + an errored ISO domain, a cluster with a down host, error/alert
  events, and a stale snapshot. The runbook raises issues; the SLI score < 1.
- **`healthy`** — everything nominal. SLI score == 1, no issues.

## Run it

Via Taskfile (from `.test/`):

```bash
task test-mock                          # start mock, run all check scripts, tear down
task test-mock MOCK_SCENARIO=healthy    # healthy variant
task mock                               # run mock in foreground on :8080
task run-sli-mock                       # run sli.robot against the mock (needs RW libs)
```

Directly:

```bash
MOCK_SCENARIO=unhealthy MOCK_PORT=8080 python3 ovirt_mock.py
# then, in another shell:
export OVIRT_ENGINE_URL=http://localhost:8080 OVIRT_USERNAME=admin@internal OVIRT_PASSWORD=mock
../../host_status.sh | jq .
```

Via Docker:

```bash
docker build -t ovirt-mock .
docker run --rm -p 8080:8080 -e MOCK_SCENARIO=unhealthy ovirt-mock
```

## Limitation

This mock reflects the **documented v4 API shape** the scripts assume — it does
**not** prove a real engine returns identical field names/types (e.g. whether
`event.time` is epoch-ms or ISO). For that, validate once against a real engine
or capture fixtures from one.
