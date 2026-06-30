# GCP Artifact Registry Spend Analysis

Analyze Google Cloud Artifact Registry and legacy Container Registry (GCR) spend from BigQuery billing export. Surfaces storage and egress cost trends, top contributors, anomalies, and optimization recommendations so operators can align artifact spend with current or required artifacts rather than stale storage.

## Overview

- **Spend breakdown**: Per-project, per-SKU artifact spend with daily, weekly, and monthly rollups
- **Top contributors**: Rank projects and SKUs; flag projects exceeding spend share thresholds
- **Month-over-month trends**: Compare the last three complete calendar months and detect storage growth without pull activity
- **Anomaly detection**: Daily storage spikes (vs 7-day average) and sustained weekly deviations from 30-day trends
- **Optimization summary**: Actionable recommendations for cleanup policies, GCR migration, duplicate tags, and scanning scope
- **SLI health score**: 0–1 score from anomaly, MoM growth, and project concentration checks

## Configuration

### Required Variables

None. When `GCP_PROJECT_IDS` is blank, projects with artifact-related billing activity are auto-discovered from the export.

### Optional Variables

- `GCP_PROJECT_IDS`: Comma-separated GCP project IDs to analyze; blank auto-discovers from billing export (default: `""`)
- `GCP_BILLING_EXPORT_TABLE`: BigQuery billing export table (`project.dataset.gcp_billing_export_v1_*`); auto-discovered if unset (default: `""`)
- `COST_ANALYSIS_LOOKBACK_DAYS`: Days of billing history to analyze (default: `30`)
- `ARTIFACT_COST_SPIKE_MULTIPLIER`: Daily cost spike threshold as multiple of 7-day average (default: `2`)
- `ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT`: Month-over-month growth percentage that triggers an issue (default: `25`)
- `ARTIFACT_PROJECT_COST_THRESHOLD_PERCENT`: Project share of total artifact spend that triggers an issue; `0` disables (default: `20`)
- `OUTPUT_FORMAT`: Report format: `table`, `csv`, `json`, or `all` (default: `table`)
- `GCP_ORG_WIDE_REPORT`: When `true`, analyze org-wide artifact spend instead of filtering to `GCP_PROJECT_IDS` (default: `false`)

### Secrets

- `gcp_credentials`: GCP service account JSON with BigQuery billing export read access (`roles/bigquery.dataViewer`, `roles/bigquery.jobUser`, `roles/bigquery.metadataViewer` on the billing export project)

## Prerequisites

1. Enable [BigQuery billing export](https://cloud.google.com/billing/docs/how-to/export-data-bigquery) for your organization.
2. Grant the service account read access to the billing export dataset.
3. Install `gcloud`, `bq`, and `jq` in the execution environment.

Artifact billing SKUs are matched using `service.description` and `sku.description` patterns for Artifact Registry, Container Registry, storage, egress, and vulnerability scanning.

**Note:** BigQuery billing export does not expose individual repository names. Correlate high-spend projects with inventory output from the `gcp-artifact-registry-governance` bundle.

## Tasks Overview

### Analyze Artifact Registry Spend by Project and SKU

Queries billing export for artifact-related SKUs and produces per-project, per-SKU totals with daily, weekly, and monthly rollups for the lookback window.

### Report Top Artifact Registry Cost Contributors

Ranks projects and SKUs by artifact storage and transfer spend. Raises issues when a project exceeds `ARTIFACT_PROJECT_COST_THRESHOLD_PERCENT` or legacy GCR SKUs dominate spend.

### Compare Artifact Registry Spend Month-over-Month

Compares artifact costs across the last three complete calendar months. Raises issues when MoM growth exceeds `ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT` or storage grows without corresponding pull/transfer activity.

### Detect Artifact Storage Cost Anomalies

Detects daily storage cost spikes at `ARTIFACT_COST_SPIKE_MULTIPLIER` times the 7-day average and sustained weekly deviations from the 30-day trend.

### Generate Artifact Registry Spend Optimization Summary

Consolidates findings into recommendations: enable cleanup policies, retire legacy GCR, reduce duplicate tags, right-size scanning, and follow up on high-cost projects with the governance bundle.

## Related Bundles

- **gcp-project-cost-health**: Organization-wide GCP cost reporting and generic optimization recommendations
- **gcp-artifact-registry-governance**: Operational inventory and cleanup-policy checks for stale artifacts
