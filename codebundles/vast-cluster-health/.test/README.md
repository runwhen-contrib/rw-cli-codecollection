# Mock scenario fixtures for vast-cluster-health.

Static JSON/Prometheus fixtures used when `VAST_MOCK_FIXTURE_DIR` is set (see `run-mock-scenarios.sh`).

| Scenario | Expected issues | Description |
|----------|-----------------|-------------|
| `healthy` | 0 | CLUSTERED state, capacity below threshold, all nodes healthy |
| `degraded` | 2+ | DEGRADED vms_state with offline DNode and active alarm |
| `capacity_pressure` | 1+ | Logical capacity above CAPACITY_THRESHOLD with no hardware faults |

Run:

```bash
cd .test
task
```
