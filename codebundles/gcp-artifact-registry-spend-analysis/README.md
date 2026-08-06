# GCP Artifact Registry Spend Analysis

Analyze Google Cloud Artifact Registry and legacy Container Registry (GCR) spend from BigQuery billing export. Surfaces storage and egress cost trends, top contributors, anomalies, and optimization recommendations so operators can align artifact spend with current or required artifacts rather than stale storage.

## Overview

- **Spend analysis**: Per-project, per-SKU artifact costs with daily, weekly, and monthly rollups from billing export
- **Top contributors**: Rank projects and SKUs; flag disproportionate project share and legacy GCR dominance
- **Month-over-month trends**: Compare the last three complete calendar months; detect storage growth without pull activity
- **Anomaly detection**: Daily cost spikes (2x 7-day average) and sustained weekly deviations from 30-day trend
- **Optimization summary**: Actionable recommendations for cleanup policies, GCR migration, and scanning right-sizing

## Configuration

### Required Variables

None. When `GCP_PROJECT_IDS` is blank, projects with artifact-related spend are inferred from the billing export.

### Optional Variables

- `GCP_PROJECT_IDS`: Comma-separated GCP project IDs to analyze; blank auto-discovers from billing export (default: `""`)
- `GCP_BILLING_EXPORT_TABLE`: BigQuery billing export table (auto-discovered if unset) (default: `""`)
- `COST_ANALYSIS_LOOKBACK_DAYS`: Days of billing history to analyze (default: `30`)
- `ARTIFACT_COST_SPIKE_MULTIPLIER`: Daily cost spike threshold as multiple of 7-day average (default: `2`)
- `ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT`: Month-over-month growth percentage that triggers an issue (default: `25`)
- `ARTIFACT_PROJECT_COST_THRESHOLD_PERCENT`: Project share of total artifact spend that triggers an issue; 0 disables (default: `20`)
- `OUTPUT_FORMAT`: Report format: `table`, `csv`, `json`, or `all` (default: `table`)

### Secrets

- `gcp_credentials`: GCP service account JSON with BigQuery billing export read access (`roles/bigquery.dataViewer`, `roles/bigquery.jobUser` on the billing export project)

## Prerequisites

1. Enable [BigQuery billing export](https://cloud.google.com/billing/docs/how-to/export-data-bigquery) for your organization
2. Install `gcloud`, `bq`, and `jq`
3. Grant the service account read access to the billing export dataset

## Tasks Overview

### Analyze Artifact Registry Spend by Project and SKU

Queries billing export for Artifact Registry and legacy GCR SKUs. Produces per-project, per-SKU totals with time rollups. May raise an issue when no artifact spend is found in the lookback window.

### Report Top Artifact Registry Cost Contributors

Ranks projects and SKUs by spend. Raises issues when a project exceeds `ARTIFACT_PROJECT_COST_THRESHOLD_PERCENT` of total artifact spend or when legacy GCR SKUs dominate spend.

### Compare Artifact Registry Spend Month-over-Month

Compares the last three complete calendar months. Raises issues when MoM growth exceeds `ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT` or when storage costs grow without corresponding transfer/pull activity.

### Detect Artifact Storage Cost Anomalies

Detects daily spikes at `ARTIFACT_COST_SPIKE_MULTIPLIER` times the 7-day average and weekly deviations from the 30-day trend.

### Generate Artifact Registry Spend Optimization Summary

Consolidates findings into recommendations: enable cleanup policies, retire legacy GCR, reduce duplicate tags, and right-size vulnerability scanning. Cross-references high-cost projects for follow-up with `gcp-artifact-registry-governance`.

## Related Bundles

- **gcp-project-cost-health**: Organization-wide GCP cost reporting
- **gcp-artifact-registry-governance**: Operational inventory and cleanup-policy checks

## Limitations

BigQuery billing export does not expose individual repository names. Repository-level attribution requires correlating high-spend projects with the governance bundle's inventory output.
