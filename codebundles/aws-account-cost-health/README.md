# AWS Account Cost Health

This codebundle monitors AWS account cost trends using the Cost Explorer API and provides Reserved Instance and Savings Plans purchase recommendations.

## Purpose

- Generate historical cost reports broken down by AWS service
- Compare current period costs against previous period
- Alert when cost increases exceed a configurable threshold
- Identify Reserved Instance (RI) and Savings Plans purchase opportunities
- Provide visibility into spending trends across linked accounts

## Tasks

### Generate AWS Cost Report By Service
Generates a detailed cost breakdown for the configured lookback period (default 30 days) showing:
- Total costs for the account
- Costs broken down by AWS service
- Period-over-period comparison with trend analysis
- Top cost movers between periods
- Multi-account breakdown (for AWS Organizations)

### Analyze AWS Reserved Instance and Savings Plans Recommendations
Queries AWS Cost Explorer for RI and Savings Plans purchase recommendations:
- EC2 Reserved Instances (1-year and 3-year terms)
- RDS Reserved Instances
- ElastiCache Reserved Nodes
- Compute Savings Plans and EC2 Instance Savings Plans
- Calculates potential monthly and annual savings

## Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `AWS_REGION` | AWS region for API calls (Cost Explorer is global but requires a region) | us-east-1 |
| `AWS_ACCOUNT_NAME` | Account name for display purposes | "" |
| `COST_ANALYSIS_LOOKBACK_DAYS` | Days to analyze for cost data | 30 |
| `COST_INCREASE_THRESHOLD` | Percentage increase that triggers an alert | 10 |
| `TIMEOUT_SECONDS` | Task timeout in seconds | 600 |

## SLI

The SLI returns:
- `1` (healthy): Costs are stable or decreasing, or increase is below threshold
- `0` (unhealthy): Cost increase exceeds the configured threshold (severity 3 or below)

Note: Severity 4 (informational) issues do not affect the SLI score.

## Requirements

- AWS credentials with the following IAM permissions:
  - `ce:GetCostAndUsage`
  - `ce:GetReservationPurchaseRecommendation`
  - `ce:GetSavingsPlansPurchaseRecommendation`
  - `sts:GetCallerIdentity`
  - `iam:ListAccountAliases`
- AWS Cost Explorer must be enabled in the account (it is enabled by default for accounts created after 2018)

## Authentication

This codebundle uses the standard RunWhen AWS authentication pattern. Credentials are imported via `RW.Core.Import Secret aws_credentials` and propagated to bash scripts through the RW.CLI library's AWS environment variable passthrough.

Supported authentication methods:
- IAM access keys
- IRSA (IAM Roles for Service Accounts)
- EKS Pod Identity
- Container credentials (ECS/Fargate)
