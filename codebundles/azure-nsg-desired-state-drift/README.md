# Azure NSG Desired-State Drift Detection

This CodeBundle compares live Azure Network Security Group (NSG) rules and subnet/NIC associations against a **baseline JSON** you maintain in source control (for example an export from `az network nsg show`, a pipeline artifact, or a normalized Terraform plan). It highlights drift from manual portal or CLI changes outside your IaC pipeline.

## Overview

- **Live export**: Reads the NSG in Azure and writes a stable, normalized JSON snapshot (`nsg_live_export.json`) including security rules, default rules, and association IDs.
- **Baseline load**: Accepts a single JSON bundle file or URL (`json-bundle`), or a directory with one file per NSG (`per-nsg-dir`), and normalizes it to the same schema.
- **Rule diff**: Flags rules that are missing, extra, or changed versus the baseline (priority, direction, access, protocol, ports, prefixes, ASGs).
- **Association audit**: If the baseline includes an `associations` object, compares subnet and NIC attachment IDs to live state.
- **Summary**: Aggregates counts, prints the Azure Portal resource URL, and suggests rollback via pipeline or IaC reconcile.

### Canonical baseline shape

Baseline objects should match the live export schema (`schemaVersion`, `subscriptionId`, `resourceGroup`, `nsgName`, `securityRules`, `defaultSecurityRules`, optional `associations`). For a bundle file, either use a single object whose `nsgName` matches the SLX NSG, or provide `{ "nsgs": [ ... ] }` / a JSON array of such objects. Teams with custom exports can adapt them with `jq` before storing the baseline.

Optional: set `IGNORE_RULE_PREFIXES` (comma-separated) to skip rule name prefixes (for example platform-specific defaults) during comparison.

## Configuration

### Required variables

- `AZURE_SUBSCRIPTION_ID`: Subscription that contains the NSG.
- `NSG_NAME`: Name of the Network Security Group for this SLX (one NSG per SLX).
- `BASELINE_PATH`: Filesystem path or `https://` URL to the baseline JSON (`json-bundle`), or a directory when `BASELINE_FORMAT` is `per-nsg-dir`.

### Optional variables

- `AZURE_RESOURCE_GROUP`: Resource group containing the NSG. If empty, the bundle discovers the resource group by listing NSGs in the subscription.
- `BASELINE_FORMAT`: `json-bundle` (default) or `per-nsg-dir`.
- `IGNORE_RULE_PREFIXES`: Comma-separated rule name prefixes excluded from drift detection.
- `COMPARE_DEFAULT_RULES`: `true` to compare `defaultSecurityRules` between live and baseline (default `false`).

### Secrets

- `azure_credentials`: JSON (or equivalent secret format) with `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_CLIENT_SECRET` for service principal sign-in, plus subscription context as required by your workspace. Grant **Reader** on the subscription or resource group and **Microsoft.Network/networkSecurityGroups/read** (included in Reader).

## Tasks overview

### Export Live NSG Rules for Comparison

Runs `az network nsg show` (and NIC listing in the resource group) and emits normalized JSON. Raises issues if the NSG cannot be resolved or read.

### Load and Normalize Baseline NSG Definition

Loads baseline content from `BASELINE_PATH`, selects the object for `NSG_NAME`, and writes `nsg_baseline_normalized.json`. Raises issues if the baseline is missing or does not contain this NSG.

### Diff Live vs Baseline and Report Drift

Compares user-defined security rules (after optional prefix filtering) and optionally default rules. Issues describe missing rules, extra live rules, or property differences.

### Validate Subnet and NIC NSG Associations

If the baseline defines `associations.subnetIds` and `associations.networkInterfaceIds`, compares sorted ID lists to live export values.

### Summarize Drift Scope for Operators

Produces a JSON summary with subscription, resource group, NSG name, Portal URL, and issue counts; emits an informational or warning-level issue for operators.
