# vast-tenant-storage-health test infrastructure

Static validation and mock VMS scenario tests run without a live VAST cluster.

## Tasks

```bash
cd .test
task
```

## Scenarios

| Scenario | Description | Expected issues |
|----------|-------------|-----------------|
| `healthy_tenant` | Tenant under quota with normal IO and latency | 0 |
| `full_view` | View at 98% logical capacity | 1+ |
| `qos_throttled` | Sustained QoS wait times and IOPS near limits | 1+ |

Mock responses live under `mock-vms/responses/<scenario>/`.
