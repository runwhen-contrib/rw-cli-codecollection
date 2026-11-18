# Elasticsearch Generic Log Search

This CodeBundle runs configurable Elasticsearch log searches using the HTTP Search API. The cluster base URL (`ELASTICSEARCH_BASE_URL`) is kept separate from the JSON query body (`ELASTICSEARCH_QUERY_BODY`) so you can reuse the same query across environments or swap endpoints without duplicating bundle logic.

## Overview

- **Endpoint reachability**: GET the configured base URL with optional basic auth or API key to confirm the HTTP API responds before running searches.
- **Generic search**: POST `ELASTICSEARCH_QUERY_BODY` to `/${ELASTICSEARCH_INDEX_PATTERN}/_search` and report total hits plus a bounded sample of hits.
- **Thresholds**: Optionally compare total hits to `SEARCH_THRESHOLD_MAX_HITS` and `SEARCH_THRESHOLD_MIN_HITS` and raise issues when out of range.
- **SLI**: Lightweight `GET /_cluster/health` probe producing a 0–1 score for periodic monitoring.

## Configuration

### Required Variables

- `ELASTICSEARCH_BASE_URL`: Base URL for the Elasticsearch HTTP API, without path (for example `https://es.example.com:9200` or `http://localhost:9200`).
- `ELASTICSEARCH_INDEX_PATTERN`: Index name or pattern used in the Search path (for example `logs-*`, `filebeat-*`, or a concrete index name).
- `ELASTICSEARCH_QUERY_BODY`: JSON body for `POST .../_search` (query, `size`, `sort`, aggregations). Do not embed the cluster base URL in this JSON.

### Optional Variables

- `SEARCH_THRESHOLD_MAX_HITS`: When set to a non-empty integer string, an issue is raised if total hits exceed this value.
- `SEARCH_THRESHOLD_MIN_HITS`: When set to a non-empty integer string, an issue is raised if total hits are below this value.
- `REQUEST_TIMEOUT_SECONDS`: HTTP timeout in seconds for probes and search (default: `60`).

### Secrets

- `elasticsearch_credentials` (optional): JSON or key-value material containing any of:
  - `ELASTICSEARCH_USERNAME` / `ELASTICSEARCH_PASSWORD` for HTTP Basic auth, and/or
  - `ELASTICSEARCH_API_KEY` for `Authorization: ApiKey ...` (Elasticsearch API key header).

Unauthenticated clusters are supported for lab use only.

## Tasks Overview

### Check Elasticsearch Endpoint Reachability

Verifies the base URL is reachable over HTTP(S) and returns a 2xx response from a lightweight GET. Issues typically indicate connection failures (severity 2) or non-success HTTP (severity 3).

### Run Generic Log Search and Summarize Results

Executes `POST ${ELASTICSEARCH_BASE_URL}/${ELASTICSEARCH_INDEX_PATTERN}/_search` with `Content-Type: application/json` and surfaces total hits plus a sample of up to 20 hits in the report. Issues surface invalid query JSON, transport errors, or non-2xx HTTP from Elasticsearch.

### Evaluate Search Result Thresholds

Reads `search_summary.json` from the previous task and compares `total_hits` to optional min/max thresholds when configured.

## Examples

Reuse the same `ELASTICSEARCH_QUERY_BODY` against two clusters by changing only the base URL:

```text
# Staging
ELASTICSEARCH_BASE_URL=https://staging-es.example.com:9200
ELASTICSEARCH_INDEX_PATTERN=logs-*
ELASTICSEARCH_QUERY_BODY={"size":5,"query":{"match_all":{}},"sort":[{"@timestamp":"desc"}]}

# Production (same query body)
ELASTICSEARCH_BASE_URL=https://prod-es.example.com:9200
ELASTICSEARCH_INDEX_PATTERN=logs-*
ELASTICSEARCH_QUERY_BODY={"size":5,"query":{"match_all":{}},"sort":[{"@timestamp":"desc"}]}
```

## API Reference

Search API: [Elasticsearch search](https://www.elastic.co/guide/en/elasticsearch/reference/current/search-search.html).
