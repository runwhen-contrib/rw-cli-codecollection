## GCP Project Cost Health & Reporting

Comprehensive toolkit for analyzing GCP costs and spending across projects using BigQuery billing export.

## Overview

This codebundle provides detailed cost analysis and reporting for Google Cloud Platform (GCP) projects. It queries your BigQuery billing export to generate comprehensive cost reports showing spending by project, service, and SKU.

## Features

### 📊 Historical Cost Reporting (`gcp_cost_historical_report.sh`)
- **Multi-Project Analysis**: Analyze costs across multiple GCP projects simultaneously
- **Service-Level Breakdown**: See costs by GCP service (Compute Engine, Cloud Storage, BigQuery, etc.)
- **SKU-Level Detail**: Drill down to individual SKUs for granular cost visibility
- **Time-Series Analysis**: Track daily spend for the last 7 days, weekly, monthly, and three-month trends
- **Cost Anomaly Detection**: Automatically detect cost spikes (2x daily average) and unusual spending patterns
- **Deviation Alerts**: Identify when weekly costs exceed monthly trends by 50% or more
- **Summary Statistics**: Quick view of total costs, high-cost contributors, and spending trends
- **Multiple Output Formats**: Table (human-readable), CSV (spreadsheet), JSON (programmatic)
- **Time-Based Analysis**: Default 30-day lookback period (configurable)

### 🌐 Network Cost Analysis (`gcp_network_cost_analysis.sh`)
- **Network-Specific Focus**: Dedicated analysis of network egress, ingress, and data transfer costs
- **SKU-Level Breakdown**: Detailed costs by network SKU (egress by region, CDN, VPN, etc.)
- **Time-Series Tracking**: Daily spend for last 7 days, weekly, monthly, and quarterly aggregation
- **Cost Anomaly Detection**: Detect network cost spikes and unusual traffic patterns
- **Project Attribution**: See which projects are generating the most network costs
- **Optimization Insights**: Actionable recommendations for reducing network egress costs
- **Multiple Output Formats**: Table, CSV, and JSON reports

### 💡 Cost Optimization Recommendations (`gcp_recommendations.sh`)
- **Committed Use Discounts (CUDs)**: Identify opportunities for 1-year and 3-year commitments
- **Idle Resource Detection**: Find unused compute instances, disks, and databases
- **Right-Sizing Recommendations**: Optimize machine types based on actual usage
- **Automated Issue Generation**: Creates actionable issues with estimated savings
- **Multi-Project Support**: Scans all accessible projects or specified project list

## Prerequisites

### 1. GCP Billing Export to BigQuery

You must have billing export enabled in your GCP organization:

```bash
# Enable billing export (run once per organization)
# This is typically done through the GCP Console:
# Billing > Billing export > BigQuery export
```

The billing export creates a BigQuery dataset with a table like:
```
project-id.billing_dataset.gcp_billing_export_v1_XXXXXX_XXXXXX_XXXXXX
```

### 2. Required GCP Permissions

The service account or user running these scripts needs permissions on **multiple resources**:

#### For Historical Cost Reporting

**On the Billing Export Project** (where BigQuery billing export is stored):
- **BigQuery Data Viewer** (`roles/bigquery.dataViewer`) - to read billing export tables
- **BigQuery Job User** (`roles/bigquery.jobUser`) - to run queries on billing data
- **BigQuery Metadata Viewer** (`roles/bigquery.metadataViewer`) - to list datasets and tables (for auto-discovery)

**Note**: The billing export project is typically a dedicated project (often named like "billing-export" or "shared") that contains the BigQuery dataset with billing export tables. This is different from the projects you're analyzing costs for.

#### For Cost Optimization Recommendations

**On Each Project Being Analyzed**:
- **Recommender Viewer** (`roles/recommender.viewer`) - to read cost optimization recommendations
- **Compute Viewer** (`roles/compute.viewer`) - to list compute instances for regional CUD recommendations
- **Project Viewer** (`roles/viewer`) - to get project names and metadata

**On Billing Account** (optional, for billing-level recommendations):
- **Billing Account Viewer** (`roles/billing.viewer`) - to access billing account information
- **Recommender Viewer** (`roles/recommender.billingAccountViewer`) - for billing-level CUD recommendations

**Important**: The Recommender API must be enabled on each project:
```bash
gcloud services enable recommender.googleapis.com --project=PROJECT_ID
```

#### Minimum IAM Permissions Setup:

```bash
# 1. Grant permissions on the billing export project (for cost reporting)
gcloud projects add-iam-policy-binding BILLING_EXPORT_PROJECT_ID \
  --member="serviceAccount:SERVICE_ACCOUNT@PROJECT.iam.gserviceaccount.com" \
  --role="roles/bigquery.dataViewer"

gcloud projects add-iam-policy-binding BILLING_EXPORT_PROJECT_ID \
  --member="serviceAccount:SERVICE_ACCOUNT@PROJECT.iam.gserviceaccount.com" \
  --role="roles/bigquery.jobUser"

gcloud projects add-iam-policy-binding BILLING_EXPORT_PROJECT_ID \
  --member="serviceAccount:SERVICE_ACCOUNT@PROJECT.iam.gserviceaccount.com" \
  --role="roles/bigquery.metadataViewer"

# 2. Grant permissions on each project being analyzed (for recommendations)
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:SERVICE_ACCOUNT@PROJECT.iam.gserviceaccount.com" \
  --role="roles/recommender.viewer"

gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:SERVICE_ACCOUNT@PROJECT.iam.gserviceaccount.com" \
  --role="roles/compute.viewer"

gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:SERVICE_ACCOUNT@PROJECT.iam.gserviceaccount.com" \
  --role="roles/viewer"

# 3. Enable Recommender API on each project
gcloud services enable recommender.googleapis.com --project=PROJECT_ID

# 4. (Optional) Grant billing account access for billing-level recommendations
gcloud beta billing accounts add-iam-policy-binding BILLING_ACCOUNT_ID \
  --member="serviceAccount:SERVICE_ACCOUNT@PROJECT.iam.gserviceaccount.com" \
  --role="roles/billing.viewer"

gcloud beta billing accounts add-iam-policy-binding BILLING_ACCOUNT_ID \
  --member="serviceAccount:SERVICE_ACCOUNT@PROJECT.iam.gserviceaccount.com" \
  --role="roles/recommender.billingAccountViewer"
```

**Important Notes**:
- The billing export tables are stored in a BigQuery project (not at the billing account level), so you need permissions on that specific project where the billing export dataset exists.
- Recommender API permissions are project-level; grant them on each project you want to analyze for cost optimization opportunities.
- Billing account permissions are optional and only needed for organization-wide CUD recommendations.

### 3. Required Tools

- `gcloud` CLI (Google Cloud SDK)
- BigQuery access (choose one):
  - `bq` command-line tool (included with gcloud): `gcloud components install bq`
  - OR Python BigQuery client: `pip install google-cloud-bigquery`
- `jq` for JSON processing
- Bash 4.0 or higher

## Installation

```bash
# Install gcloud SDK
curl https://sdk.cloud.google.com | bash
exec -l $SHELL

# Initialize gcloud
gcloud init

# Authenticate
gcloud auth login
gcloud auth application-default login

# Install jq (if not already installed)
# Ubuntu/Debian:
sudo apt-get install jq

# macOS:
brew install jq
```

## Configuration

### Environment Variables

| Variable | Description | Required | Example |
|----------|-------------|----------|---------|
| `GCP_PROJECT_IDS` | Comma-separated list of project IDs to analyze. If left blank, will assess all projects found in the billing export | No | `project-1,project-2` |
| `GCP_BILLING_EXPORT_TABLE` | BigQuery table path for billing export (auto-discovered if not provided) | No | `billing-project.billing_dataset.gcp_billing_export_v1_012345_ABCDEF_123ABC` |
| `COST_ANALYSIS_LOOKBACK_DAYS` | Number of days to analyze (default: 30) | No | `30` |
| `GCP_COST_BUDGET` | Optional budget threshold in USD. A severity 3 issue will be raised if total costs exceed this amount. Set to 0 to disable. | No | `50000` |
| `GCP_PROJECT_COST_THRESHOLD_PERCENT` | Optional percentage threshold (0-100). A severity 3 issue will be raised if any single project exceeds this percentage of total costs. Set to 0 to disable. | No | `25` |
| `NETWORK_COST_THRESHOLD_MONTHLY` | Minimum monthly network cost (in USD) to generate severity 3 alerts. SKUs below this threshold are excluded from analysis. Default: 200 | No | `200` |
| `OUTPUT_FORMAT` | Output format: `table`, `csv`, `json`, or `all` | No | `table` |

### Billing Export Table Auto-Discovery

The script will automatically discover your billing export table if `GCP_BILLING_EXPORT_TABLE` is not provided. It searches for tables matching the pattern `gcp_billing_export_v1_*` across accessible BigQuery datasets and verifies they have the correct schema.

If you need to manually find or specify your billing export table:

```bash
# List your BigQuery datasets
bq ls

# List tables in your billing dataset
bq ls billing_dataset

# The table name will look like:
# gcp_billing_export_v1_012345_ABCDEF_123ABC
```

### Project Auto-Discovery

If `GCP_PROJECT_IDS` is left blank or empty, the script will automatically query the billing export table to find all projects that have costs in the specified date range. This is useful for getting a comprehensive view of all spending across your organization without having to manually specify each project.

**Note**: When using project auto-discovery, the script will only include projects that have costs > 0 in the specified date range.

### Budget Tracking & Alerting

The codebundle includes optional budget tracking features that raise severity 3 issues when costs exceed configured thresholds:

#### Total Budget Threshold (`GCP_COST_BUDGET`)
Set a total budget threshold in USD. If your total GCP costs exceed this amount, a severity 3 issue will be raised with:
- Total cost vs. budget comparison
- Overage amount and percentage
- Full cost report attached to issue details

Example: Set `GCP_COST_BUDGET=50000` to alert when total costs exceed $50,000.

#### Per-Project Cost Threshold (`GCP_PROJECT_COST_THRESHOLD_PERCENT`)
Set a percentage threshold to identify projects consuming a disproportionate amount of your budget. If any single project exceeds this percentage of total costs, a severity 3 issue will be raised for that project.

Example: Set `GCP_PROJECT_COST_THRESHOLD_PERCENT=25` to alert if any project accounts for more than 25% of total costs.

**Use Cases:**
- **Budget Enforcement**: Get notified when you're approaching or exceeding budget limits
- **Cost Anomaly Detection**: Identify projects with unexpectedly high spending
- **Cost Distribution Monitoring**: Ensure no single project is dominating your cloud spend

Leave both values at `0` to disable budget tracking.

### Cost Anomaly Detection

The codebundle now includes automatic anomaly detection that analyzes spending patterns over time and raises issues for:

#### Daily Cost Spikes (Severity 2)
- **Detection**: Identifies when a single day's cost is 2x or more than the 7-day average
- **Use Case**: Catch unexpected resource usage, batch jobs, or misconfigurations early
- **Example**: If average daily cost is $100, an alert triggers when a day reaches $200+

#### Weekly Cost Deviations (Severity 3)
- **Detection**: Compares last 7 days cost to expected weekly cost (based on 30-day trend)
- **Threshold**: Alerts when weekly cost is 50% higher than expected
- **Use Case**: Identify sustained increases in spending or new services driving costs up

#### Network Cost Alert Threshold
Network cost anomaly detection includes a minimum monthly cost threshold to reduce noise from low-cost items:
- **Default Threshold**: $50/month per SKU
- **Smart Query Optimization**: Uses a two-stage approach to minimize BigQuery costs:
  1. First queries a lightweight summary of monthly costs per SKU
  2. Filters to only SKUs above the threshold (e.g., 15 out of 50 SKUs)
  3. Then queries detailed time-series data for only those high-cost SKUs
  4. Result: ~85-90% reduction in data processed compared to querying all SKUs
- **Behavior**: SKUs will be analyzed and generate severity 3 alerts if:
  - Current monthly cost exceeds the threshold, OR
  - Recent spending rate (last 7 days) projects to breach the threshold
- **Rationale**: Prevents alert fatigue from trivial network costs while providing early warning when costs are trending toward the threshold
- **Configuration**: Set `NETWORK_COST_THRESHOLD_MONTHLY` to your preferred threshold in USD (default: $200/month ≈ $6.67/day)
- **Examples**: 
  - SKU at $50/month with stable daily rate: No alert (below threshold, not trending up)
  - SKU at $150/month with recent daily rate of $10/day: **Alert** (projects to $300/month)
  - SKU at $250/month: **Alert** (already exceeds threshold)
- **All Below Threshold**: If all network costs are below the threshold and not trending toward it, the script reports this clearly

#### Alert Types

**1. Current High Cost** (Severity 3):
- Monthly cost already exceeds threshold
- Example: "Currently spending $500/month on Cloud NAT Data Processing"

**2. Projected Breach** (Severity 3):
- Current monthly cost is below threshold
- But recent daily spending rate projects to breach threshold
- Example: "Current spend is $150/month, but recent daily rate of $10/day projects to $300/month"
- Provides early warning before costs escalate

**Issue Details Include:**
- Monthly and daily average costs for better understanding
- Projected monthly cost (based on recent 7-day trend)
- Configured threshold for context
- Optimization recommendations specific to the SKU type

#### Time-Series Analysis
The enhanced cost reporting now tracks:
- **Daily Spend**: Each of the last 7 days individually
- **Weekly Spend**: Rolling 7-day total
- **Monthly Spend**: Last 30 days
- **Quarterly Spend**: Last 90 days

This time-series data enables:
- Trend analysis and forecasting
- Comparison across time periods
- Early detection of cost anomalies
- Validation of cost optimization efforts

## Usage

### Standalone Execution

#### Historical Cost Reporting

```bash
# Set required environment variables
export GCP_PROJECT_IDS="my-project-1,my-project-2"

# Optional: Specify billing table (will auto-discover if not provided)
export GCP_BILLING_EXPORT_TABLE="billing-project.billing_dataset.gcp_billing_export_v1_012345"

# Run the cost historical report
./gcp_cost_historical_report.sh
```

#### Network Cost Analysis

```bash
# Set required environment variables
export GCP_PROJECT_IDS="my-project-1,my-project-2"

# Optional: Specify billing table (will auto-discover if not provided)
export GCP_BILLING_EXPORT_TABLE="billing-project.billing_dataset.gcp_billing_export_v1_012345"

# Run the network cost analysis
./gcp_network_cost_analysis.sh
```

The network analysis script will:
1. Query all network-related costs (egress, ingress, CDN, VPN, etc.)
2. Break down costs by SKU and project
3. Show daily spend for the last 7 days
4. Calculate weekly, monthly, and quarterly totals
5. Detect cost anomalies and spikes (2x daily average)
6. Generate issues for significant deviations

#### Cost Optimization Recommendations

```bash
# Set optional environment variables (leave blank to scan all accessible projects)
export GCP_PROJECT_IDS="my-project-1,my-project-2"

# Run the recommendations fetch
./gcp_recommendations.sh
```

The recommendations script will:
1. Scan all specified projects (or auto-discover all accessible projects)
2. Check billing account and organization-level recommendations
3. Fetch project-level recommendations for each project
4. Generate a consolidated report grouping CUD recommendations
5. Create issues JSON with estimated savings

### Output Files

#### Historical Cost Reports
- **`gcp_cost_report.txt`**: Human-readable table format with time-series analysis
- **`gcp_cost_report.csv`**: Spreadsheet-compatible CSV (if OUTPUT_FORMAT includes csv)
- **`gcp_cost_report.json`**: Machine-readable JSON (if OUTPUT_FORMAT includes json)
- **`gcp_cost_issues.json`**: Issues generated for budget threshold violations and cost anomalies
  - Budget threshold violations (if configured)
  - Daily cost spikes (2x average)
  - Weekly vs monthly cost deviations (50%+ increase)

#### Network Cost Analysis
- **`gcp_network_cost_report.txt`**: Human-readable network cost breakdown by SKU
- **`gcp_network_cost_report.csv`**: CSV format with daily/weekly/monthly/quarterly data
- **`gcp_network_cost_report.json`**: JSON format for programmatic access
- **`gcp_network_cost_issues.json`**: Issues generated for network cost anomalies
  - Network cost spikes (2x daily average)
  - Weekly network cost deviations
  - Unusual traffic patterns

#### Cost Optimization Recommendations
- **`gcp_cost_recommendations.txt`**: Human-readable report of all recommendations
- **`gcp_recommendations_issues.json`**: Machine-readable issues with estimated savings
  - **CUD recommendations grouped into a single issue** with project breakdown
  - Individual issues for other cost optimizations (idle resources, right-sizing, etc.)

### Example Output

```
╔══════════════════════════════════════════════════════════════════════╗
║          GCP COST REPORT - LAST 30 DAYS                             ║
║          Period: 2025-10-15 to 2025-11-14                           ║
╚══════════════════════════════════════════════════════════════════════╝

📊 COST SUMMARY
════════════════════════════════════════════════════════════════════════

   💰 Total Cost Across All Projects:    $15234.67
   🔐 Projects Analyzed:                  5
   ⚠️  High Cost Contributors (>20%):     2
   📊 Significant Contributors (>1%):    4
   🔍 Top Cost Projects (Top 25%):       2
   💤 Projects Under $1:                   1

────────────────────────────────────────────────────────────────────────

💳 COST BY PROJECT:
   • production-webapp: $8920.45
   • data-analytics-prod: $4128.90
   • staging-environment: $1876.32
   • dev-testing: $287.00
   • sandbox-project: $22.00

════════════════════════════════════════════════════════════════════════

📋 TOP 10 PROJECTS BY COST
════════════════════════════════════════════════════════════════════════

   PROJECT                              COST          %
────────────────────────────────────────────────────────────────────────

 1. production-webapp                   $  8920.45  (58%)
 2. data-analytics-prod                 $  4128.90  (27%)
 3. staging-environment                 $  1876.32  (12%)
 4. dev-testing                         $   287.00  ( 1%)
 5. sandbox-project                     $    22.00  ( 0%)
```

## Cost Optimization Tips

The report includes actionable recommendations:

- ✅ **Review high-cost projects** for optimization opportunities
- ✅ **Check for unused resources** in low-spend projects
- ✅ **Consider committed use discounts** for predictable workloads
- ✅ **Enable cost anomaly detection** and budgets
- ✅ **Review storage classes** and lifecycle policies
- ✅ **Use preemptible VMs** for fault-tolerant workloads

## Multi-Project Analysis

The scripts support analyzing multiple projects simultaneously:

```bash
export GCP_PROJECT_IDS="prod-project-1,prod-project-2,dev-project,staging-project"
./gcp_cost_historical_report.sh
```

Results are:
- ✅ Aggregated across all projects
- ✅ Sorted by total cost
- ✅ Grouped by project and service
- ✅ Failed projects logged but don't stop analysis

## Troubleshooting

### "No cost data available"

**Possible causes:**
1. Billing export not enabled or configured
2. No costs incurred in the analysis period
3. Insufficient BigQuery permissions
4. Incorrect billing table path

**Solutions:**
```bash
# Verify billing export is enabled
gcloud alpha billing accounts list

# Check BigQuery access
bq ls

# Verify project access
gcloud projects list

# Test a simple query
bq query --use_legacy_sql=false \
  "SELECT SUM(cost) as total FROM \`your-billing-table\` LIMIT 1"
```

### "BigQuery access denied" or "Cannot list datasets"

This usually means insufficient permissions on the **billing export project** (where the BigQuery billing export dataset is stored).

**Understanding the Architecture:**
- **Billing Account**: Organization-level, no project
- **Billing Export Tables**: Stored in a BigQuery project (often named "billing-export", "shared", or similar)
- **Projects Being Analyzed**: The projects you want cost data for (different from billing export project)

**Solution**: Grant the required roles on the **billing export project**:

```bash
# Identify the billing export project (where your billing export dataset is located)
# Check in GCP Console: Billing > Billing export > BigQuery export
# Or look for a project with a dataset containing tables like gcp_billing_export_v1_*

# Grant BigQuery roles on the billing export project
gcloud projects add-iam-policy-binding BILLING_EXPORT_PROJECT_ID \
  --member="serviceAccount:YOUR_SERVICE_ACCOUNT@PROJECT.iam.gserviceaccount.com" \
  --role="roles/bigquery.dataViewer"

gcloud projects add-iam-policy-binding BILLING_EXPORT_PROJECT_ID \
  --member="serviceAccount:YOUR_SERVICE_ACCOUNT@PROJECT.iam.gserviceaccount.com" \
  --role="roles/bigquery.jobUser"

gcloud projects add-iam-policy-binding BILLING_EXPORT_PROJECT_ID \
  --member="serviceAccount:YOUR_SERVICE_ACCOUNT@PROJECT.iam.gserviceaccount.com" \
  --role="roles/bigquery.metadataViewer"
```

**Finding Your Billing Export Project:**
```bash
# List all projects and look for billing-related ones
gcloud projects list

# Or check BigQuery datasets across projects
bq ls --project_id=PROJECT_ID
```

### "Project access denied"

```bash
# Grant project viewer role on each project
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="user:YOUR_EMAIL" \
  --role="roles/viewer"
```

### "Recommender API not enabled" or "No recommendations found"

**If you see warnings about Recommender API not being enabled:**

```bash
# Enable the Recommender API on each project
gcloud services enable recommender.googleapis.com --project=PROJECT_ID
```

**If the API is enabled but you still see no recommendations:**
1. **Recommendations take time to generate**: GCP needs 7-14 days of usage data to generate recommendations
2. **Check permissions**: Ensure you have `roles/recommender.viewer` on the project
3. **Resources must exist**: Projects need active resources (compute instances, disks, etc.) to receive recommendations
4. **Manual verification**: Check GCP Console > Recommendations to see if recommendations exist

**To verify Recommender API access:**

```bash
# List available recommenders for a project
gcloud recommender recommenders list --project=PROJECT_ID

# List recommendations for a specific recommender
gcloud recommender recommendations list \
  --project=PROJECT_ID \
  --location=us-central1 \
  --recommender=google.compute.instance.MachineTypeRecommender
```

## Best Practices

### Regular Cost Reviews

Run these reports regularly to:
- Track spending trends over time
- Identify cost anomalies early
- Validate optimization efforts
- Support budget planning

### Scheduling

Use cron or Cloud Scheduler to run automatically:

```bash
# Daily cost report at 9 AM
0 9 * * * /path/to/gcp_cost_historical_report.sh
```

### Cost Allocation

Use project labels and naming conventions:
- `env-production`
- `team-data-science`
- `cost-center-engineering`

This makes cost analysis more meaningful.

## Limitations

- **Billing Export Delay**: Cost data typically has a 24-48 hour delay
- **Query Costs**: BigQuery queries incur small costs (typically < $0.01 per run)
- **Historical Data**: Limited to the retention period of your billing export
- **Large Datasets**: Very large billing exports may require query optimization

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review GCP documentation on billing export
3. Verify permissions and configuration
4. Check script logs for detailed error messages

## Related Resources

- [GCP Billing Export Documentation](https://cloud.google.com/billing/docs/how-to/export-data-bigquery)
- [BigQuery Billing Export Schema](https://cloud.google.com/billing/docs/how-to/export-data-bigquery-tables)
- [GCP Cost Management Best Practices](https://cloud.google.com/cost-management)
- [Committed Use Discounts](https://cloud.google.com/compute/docs/instances/signing-up-committed-use-discounts)

## License

This codebundle is part of the RunWhen workspace automation platform.



