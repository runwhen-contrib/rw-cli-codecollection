---
name: curl-http-ok
kind: skill-template
description: This taskset uses curl to validate the response code of the endpoint and provides the total time of the request. Use when triaging or monitoring Linux, macOS, Windows workloads with skill template ...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [Linux, macOS, Windows, HTTP]
resource_types: []
access: read-only
---

# cURL HTTP OK

## Summary

This codebundle validates the response code of an endpoint using cURL and provides the total time of the request.

See [README.md](README.md) for additional context.

## Tools

### Check HTTP URL Availability and Timeliness

Use cURL to validate single or multiple http responses

- **Robot task name**: <code>Check HTTP URL Availability and Timeliness</code>
- **Robot file**: `runbook.robot`
- **Tags**: `curl`, `http`, `ingress`, `latency`, `errors`, `access:read-only`, `data:config`
- **Reads**: `URLS`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

This taskset uses curl to validate the response code of the endpoint. Returns ascore of 1 if healthy, an 0 if unhealthy.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Validate HTTP URL Availability and Timeliness

Use cURL to validate single or multiple http responses

- **Robot task name**: <code>Validate HTTP URL Availability and Timeliness</code>
- **Sub-metric name**: `overall_health`
- **Tags**: `cURL`, `HTTP`, `Ingress`, `Latency`, `Errors`, `data:config`
- **Reads**: `URLS`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `URLS` | string | Comma-separated list of URLs to perform requests against. | `https://www.runwhen.com` | no |
| `TARGET_LATENCY` | string | The maximum latency in seconds as a float value allowed for requests to have. | `1.2` | no |
| `ACCEPTABLE_RESPONSE_CODES` | string | Comma-separated list of HTTP response codes that indicate success and connectivity (e.g., 200,201,202,204,301,302,307,401,403). | `200,201,202,204,301,302,307,401,403` | no |
| `OWNER_DETAILS` | string | Json list of owner details | `{"name": "my-ingress", "kind": "Ingress", "namespace": "default"}` | no |
| `VERIFY_SSL` | string | Whether to verify SSL certificates. Set to 'false' to ignore SSL certificate errors. | `false` | no |

## Secrets

_No secrets imported in Robot source._

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/curl-http-ok
export URLS=...
export TARGET_LATENCY=...
export ACCEPTABLE_RESPONSE_CODES=...
export OWNER_DETAILS=...
export VERIFY_SSL=...
ro runbook.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
