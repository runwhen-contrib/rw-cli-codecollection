# Cloudflare Zone WAF & Security Events Report

This CodeBundle reads sampled firewall and security-adjacent rows from Cloudflare’s GraphQL Analytics `firewallEventsAdaptive` dataset, aggregates them by mitigating rule/action/source, enriches the picture with IP / ASN / country / hostname breakdowns, compares configurable thresholds, and emits an operational correlation summary plus binary SLI scoring hooks.

## Overview

- **Firewall event ingestion**: Uses HTTPS POST to `https://api.cloudflare.com/client/v4/graphql` with bearer-token authentication and bounded pagination so sampled datasets remain reproducible even during bursts ([tutorial](https://developers.cloudflare.com/analytics/graphql-api/tutorials/querying-firewall-events/)).
- **Adaptive sampling transparency**: Cloudflare applies adaptive sampling to Firewall Analytics rows — dashboard totals may extrapolate beyond the sampled hits returned to GraphQL ([details](https://developers.cloudflare.com/analytics/graphql-api/sampling/)).
- **Threshold-aware storytelling**: Raises structured RunWhen issues when aggregate sampled volumes or concentrated buckets exceed operator knobs or spike-ratio comparisons versus an optional trailing baseline window.
- **Operational artifacts**: Writes normalized JSON (rule aggregates, IP correlations, host/path summaries) beside textual rollup outputs suitable for handoffs.

## Configuration

### Required variables

- `CLOUDFLARE_ZONE_ID`: Zone identifier (`zoneTag`) passed into GraphQL filters (`zones(filter:{ zoneTag })`).
- `cloudflare_api_token` secret: API bearer token that satisfies Analytics/Firewall read scopes documented under Cloudflare token templates — expose via RunWhen secrets as plain text ([guidance](https://developers.cloudflare.com/analytics/graphql-api/getting-started/authentication/api-token-auth/)).

### Optional variables

- `CLOUDFLARE_ACCOUNT_ID`: Retained for future account-level filtering hooks when datasets demand additional qualifiers (currently informational metadata inside fetched payloads).
- `WAF_LOOKBACK_MINUTES`: Primary sliding-window length (minutes). Default `60`.
- `WAF_COMPARE_LOOKBACK_MINUTES`: Immediately preceding baseline window length (minutes); `0` disables spike-ratio comparisons. Default `60`.
- `WAF_TOTAL_EVENTS_ISSUE_THRESHOLD`: Sampled-row ceiling across the primary window before emitting aggregate-volume issues. Default `500`.
- `WAF_TOP_ENTITY_ISSUE_THRESHOLD`: Ceiling per concentrated bucket (dominant rule group, IP, host/path bucket). Default `100`.
- `WAF_SPIKE_RATIO_THRESHOLD`: Minimum ratio (`primary_sample_total / prior_sample_total`) before emitting spike issues; `0` disables the spike heuristic entirely (floating decimals supported). Default `0`.
- `WAF_REPORT_TOP_N`: Rank tables truncated after `N` entries in correlators/report sections. Default `15`.
- `WAF_FETCH_PAGE_LIMIT`: Rows requested per GraphQL page (`limit`). Default `800`.
- `WAF_FETCH_MAX_PAGES`: Pagination guard to bound worst-case runtime/credit consumption. Default `25`.

### SLI-only knobs (`sli.robot`)

Configure alongside runbook secrets via workspace/template mappings:

- `SLI_WAF_LOOKBACK_MINUTES`: Minutes sampled inside SLI probe windows — keep ≤15 for rapid evaluations (default `15`).
- `SLI_WAF_MAX_SAMPLE_ROWS`: GraphQL `limit` applied exclusively inside SLI (default `400`).
- `SLI_WAF_MAX_EVENTS`: Fail volume dimension when sampled SLI rows exceed this ceiling (default `250`).

## Tasks Overview

### Fetch Firewall and WAF Events for Zone `${CLOUDFLARE_ZONE_ID}`

Runs GraphQL pagination, persists normalized JSON blobs (`cloudflare_waf_primary_normalized.json`, optional prior-window sibling JSON), and opens severity issues whenever DNS/network/schema/token faults occur mid-fetch.

### Aggregate WAF Events by Rule, Action, and Service for Zone `${CLOUDFLARE_ZONE_ID}`

Clusters sampled hits using `.ruleId` where Cloudflare supplies identifiers — grouping gracefully collapses unknown identifiers — grouped jointly by mitigation `.source`/`.action` values.

### Correlate WAF Events by Source IP and Country for Zone `${CLOUDFLARE_ZONE_ID}`

Produces ranked IPs, autonomous-system aggregates, and country histogram sections honoring `WAF_REPORT_TOP_N`.

### Break Down WAF Activity by Hostname and Request Path for Zone `${CLOUDFLARE_ZONE_ID}`

Combines optional `.clientRequestHTTPHostName` with `.clientRequestPath` buckets plus standalone hostname summaries whenever hostname dimensions populate.

### Evaluate WAF Volume and Spike Thresholds for Zone `${CLOUDFLARE_ZONE_ID}``

Loads aggregator artifacts plus prior-window totals when spike ratios configured — emits remediation-heavy RunWhen issues with remediation bullets referencing dashboards versus definitive logs.

### Produce Consolidated WAF Correlation Report for Zone `${CLOUDFLARE_ZONE_ID}``

Concatenates key rollup summaries referencing aggregated artifacts plus pinned Cloudflare documentation links for responders auditing anomalies offline.
