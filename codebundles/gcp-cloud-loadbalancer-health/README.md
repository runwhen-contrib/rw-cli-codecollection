# GCP Cloud Load Balancer Health

This CodeBundle monitors the health and performance of GCP Cloud Load Balancers (external HTTP/S, internal HTTP/S, SSL proxy, TCP proxy, and network load balancers). It checks SSL certificate validity, backend health status, error rates via Cloud Monitoring, and latency performance to ensure load balancers are operating within normal operational parameters.

## Overview

The bundle discovers all forwarding rules in a project and analyzes each load balancer across four dimensions:

- **SSL certificate health**: Flags SSL certificates that expire within `SSL_WARNING_DAYS` on HTTPS and SSL proxy load balancers
- **Backend health**: Flags unhealthy backends, draining instances, and degraded capacity on backend services
- **Error rates**: Flags HTTP/S load balancers whose 5xx error ratio exceeds `ERROR_RATE_THRESHOLD` using Cloud Monitoring
- **Latency performance**: Flags load balancers whose P95 latency exceeds `LATENCY_THRESHOLD_MS`

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: The GCP project ID where the load balancers are deployed.

### Optional Variables

- `SSL_WARNING_DAYS`: Number of days before SSL certificate expiry to raise a warning (severity 2) or alert (severity 3). (default: `30`)
- `ERROR_RATE_THRESHOLD`: Maximum acceptable 5xx error ratio as a decimal (e.g., `0.01` = 1%). (default: `0.01`)
- `LATENCY_THRESHOLD_MS`: Maximum acceptable P95 latency in milliseconds. (default: `5000`)
- `METRIC_LOOKBACK_PERIOD`: Cloud Monitoring lookback period for metric queries in seconds (e.g., `3600s`, `86400s`). (default: `3600s`)

### Secrets

- `gcp_credentials`: A GCP service account JSON key with `roles/compute.viewer` and `roles/monitoring.viewer`. Format is the standard GCP service account JSON object (containing `type`, `project_id`, `private_key_id`, `private_key`, `client_email`, `client_id`, `auth_uri`, `token_uri`).

## SLI

The SLI produces a continuous 0-1 health score, averaged across four dimensions (each pushed as a sub-metric):

- `ssl_certificate_health` — 1.0 if no certs expire within `SSL_WARNING_DAYS`, else 0.0
- `backend_health` — ratio of healthy backends to total backends across all load balancers
- `error_rate` — 1.0 if all load balancers are below `ERROR_RATE_THRESHOLD`, else 0.0
- `latency_performance` — 1.0 if all load balancers are below `LATENCY_THRESHOLD_MS`, else 0.0

The aggregate is the arithmetic mean of the four dimension scores.

## Tasks Overview

### Discover GCP Cloud Load Balancers and Configurations
Lists all forwarding rules in the project, categorizes each by load balancer type (HTTP/S, SSL proxy, TCP proxy, Network), and dumps configuration including IP address, ports, target proxy, and backend service. Produces a configuration dump used by the other tasks.

### Check SSL Certificate Expiry for HTTPS/SSL Load Balancers
For all HTTPS and SSL proxy load balancers, inspects the mapped SSL certificates and flags any that expire within `SSL_WARNING_DAYS`, reporting the days remaining per certificate. Detects expiring and expired certificates.

### Check Load Balancer Backend Health
For each backend service referenced by the project's load balancers, checks backend health status and flags unhealthy backends, draining instances, and backends with degraded capacity.

### Analyze Load Balancer Error Rates via Cloud Monitoring
Queries Cloud Monitoring metrics for HTTP/S load balancer 5xx error ratios and non-HTTP LB error rates over the lookback period, flagging load balancers whose error rate exceeds `ERROR_RATE_THRESHOLD`.

### Analyze Load Balancer Latency Performance
Queries Cloud Monitoring metrics for request latency (P95) on HTTP/S load balancers, flagging load balancers whose latency exceeds `LATENCY_THRESHOLD_MS`.

### Generate Load Balancer Health Summary
Aggregates findings from all previous checks into a consolidated health summary table showing each load balancer, its type, SSL status, backend status, error rate, latency, and an overall health verdict.

## Requirements

The following IAM permissions are required on the service account (via a custom role, or `roles/compute.viewer` + `roles/monitoring.viewer`):

- `compute.forwardingRules.list`
- `compute.backendServices.getHealth`
- `compute.sslCertificates.list`
- `compute.targetHttpsProxies.list`
- `compute.targetSslProxies.list`
- `compute.targetHttpProxies.list`
- `compute.targetTcpProxies.list`
- `monitoring.metricDescriptors.list`
- `monitoring.timeSeries.list`

The `gcloud`, `jq`, and `curl` CLI tools are required at runtime. The Compute Engine and Cloud Monitoring APIs must be enabled for the project.
