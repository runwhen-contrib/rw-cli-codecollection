---
name: dns-health
kind: skill-template
description: This taskset performs comprehensive DNS health monitoring and validation tasks. Use when triaging or monitoring DNS, Azure, GCP workloads with skill template `dns-health`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [DNS, Azure, GCP, AWS]
resource_types: [azure_resource]
access: read-only
---

# DNS Health & Monitoring

## Summary

This taskset performs comprehensive DNS health monitoring and validation tasks.

See [README.md](README.md) for additional context.

## Tools

### Check DNS Zone Records

Verifies DNS zones and their record integrity

- **Robot task name**: <code>Check DNS Zone Records</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `dns`, `zone-records`, `data:config`
- **Reads**: `DNS_ZONES`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Detect Broken Record Resolution

Implements repeated DNS checks for multiple FQDNs to detect resolution failures

- **Robot task name**: <code>Detect Broken Record Resolution</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `dns`, `resolution`, `consistency`, `data:config`
- **Reads**: `DNS_RESOLVERS`, `TEST_FQDNS`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Test Forward Lookup Zones

Tests forward lookup zones and conditional forwarders for proper resolution

- **Robot task name**: <code>Test Forward Lookup Zones</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `dns`, `forward-lookup`, `conditional-forwarders`, `data:config`
- **Reads**: `FORWARD_LOOKUP_ZONES`, `FORWARD_ZONE_TEST_SUBDOMAINS`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### External Resolution Validation

Tests resolution of multiple public domains through multiple resolvers

- **Robot task name**: <code>External Resolution Validation</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `dns`, `external`, `public`, `resolvers`, `data:config`
- **Reads**: `DNS_RESOLVERS`, `PUBLIC_DOMAINS`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### DNS Latency Check

Tests DNS query latency for configured zones

- **Robot task name**: <code>DNS Latency Check</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `dns`, `latency`, `performance`, `data:config`
- **Reads**: `DNS_ZONES`, `FORWARD_LOOKUP_ZONES`, `TEST_FQDNS`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

This SLI measures DNS health metrics including resolution success rates,

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### DNS Resolution Success Rate

Measures the success rate of DNS resolution across all configured FQDNs and pushes a metric (0-100)

- **Robot task name**: <code>DNS Resolution Success Rate</code>
- **Sub-metric name**: `resolution_success`
- **Tags**: `dns`, `resolution`, `success-rate`, `sli`, `data:config`
- **Reads**: `FORWARD_LOOKUP_ZONES`, `PUBLIC_DOMAINS`, `TEST_FQDNS`


#### DNS Query Latency

Measures average DNS query latency in milliseconds across all configured FQDNs and pushes the metric

- **Robot task name**: <code>DNS Query Latency</code>
- **Sub-metric name**: `latency_performance`
- **Tags**: `dns`, `latency`, `performance`, `sli`, `data:config`
- **Reads**: `FORWARD_LOOKUP_ZONES`, `PUBLIC_DOMAINS`, `TEST_FQDNS`


#### DNS Zone Health

Measures the health of configured DNS zones (1 for healthy, 0 for unhealthy)

- **Robot task name**: <code>DNS Zone Health</code>
- **Sub-metric name**: `zone_health`
- **Tags**: `dns`, `zone-health`, `sli`, `data:config`
- **Reads**: `DNS_ZONES`


#### External DNS Resolver Availability

Measures availability of external DNS resolvers (percentage of working resolvers)

- **Robot task name**: <code>External DNS Resolver Availability</code>
- **Sub-metric name**: `resolver_availability`
- **Tags**: `dns`, `external`, `resolver`, `availability`, `sli`, `data:config`
- **Reads**: `DNS_RESOLVERS`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `TEST_FQDNS` | string | Important domains/services to monitor for DNS resolution (comma-separated if multiple). Example: api.mycompany.com,db.mycompany.com | `google.com,example.com` | no |
| `FORWARD_LOOKUP_ZONES` | string | Internal company domains that forward to on-premises DNS (optional, for hybrid environments). Example: internal.company.com | `""` | no |
| `PUBLIC_DOMAINS` | string | Your public websites to test external DNS resolution (optional). Example: mycompany.com,blog.mycompany.com | `""` | no |
| `DNS_RESOLVERS` | string | Custom DNS servers to test against (comma-separated). Example: 10.0.0.4,10.0.1.4 or 8.8.8.8,1.1.1.1 | `8.8.8.8,1.1.1.1` | no |
| `DNS_ZONES` | string | DNS zones to check health for (comma-separated). Can be private or public zones. Example: mycompany.com,internal.corp | `""` | no |
| `FORWARD_ZONE_TEST_SUBDOMAINS` | string | Specific servers to test in forward lookup zones (optional). Example: dc01,mail,web | `""` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/dns-health/runbook.robot`
- **Monitor**: `codebundles/dns-health/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/dns-health
export TEST_FQDNS=...
export FORWARD_LOOKUP_ZONES=...
export PUBLIC_DOMAINS=...
export DNS_RESOLVERS=...
export DNS_ZONES=...
export FORWARD_ZONE_TEST_SUBDOMAINS=...
ro runbook.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
