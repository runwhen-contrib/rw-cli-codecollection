# Azure NSG Desired-State Drift Detection

This CodeBundle compares live Azure Network Security Group (NSG) rules and subnet or NIC associations against a repository-managed baseline (for example an `az network nsg show` export or a bundled JSON file from your IaC pipeline). It helps surface out-of-band changes from the portal or ad hoc CLI work that were not applied through your declared configuration.

## Overview

- **Live export**: Enumerates NSGs in scope, normalizes security rules and default rules into a stable JSON shape, and writes `nsg_live_bundle.json`.
- **Baseline load**: Reads `BASELINE_PATH` as a single json-bundle file (`nsgs` array) or a directory of per-NSG JSON files (`BASELINE_FORMAT=per-nsg-dir`).
- **Diff**: Compares live vs baseline rule-by-rule (optionally including default rules) with optional `IGNORE_RULE_PREFIXES` to skip platform-style names.
- **Associations**: Reads subnet and NIC references from each NSG and optionally compares them to `ASSOCIATION_BASELINE_PATH`.
- **Summary**: Rolls up counts, prints Azure Portal links for NSGs in scope, and suggests IaC rollback paths.

## Configuration

### Required variables

- `AZURE_SUBSCRIPTION_ID`: Subscription that contains the NSGs.
- `BASELINE_PATH`: Filesystem path to the baseline (json-bundle file or directory of JSON files).

### Optional variables

- `AZURE_RESOURCE_GROUP`: Limit listing to one resource group. When empty, NSGs are listed subscription-wide (can be slower).
- `NSG_NAMES`: Comma-separated NSG names, or `All` for every NSG in scope.
- `NSG_NAME`: When set (for example by platform generation for one SLX), only this NSG is analyzed; it overrides the effective filter from `NSG_NAMES`.
- `BASELINE_FORMAT`: `json-bundle` (default) or `per-nsg-dir`.
- `ASSOCIATION_BASELINE_PATH`: Optional JSON file describing expected `subnetIds` and `nicIds` per NSG for association drift.
- `COMPARE_DEFAULT_RULES`: `true` or `false` (default `false`). When `false`, only user-defined `securityRules` are compared; default Azure rules are skipped.
- `IGNORE_RULE_PREFIXES`: Comma-separated prefixes; rules whose names start with any prefix are skipped in the diff.
- `REQUIRE_ASSOCIATIONS`: `true` or `false` (default `false`). When `true`, emits a warning if an NSG has no subnet or NIC attachments.

### Secrets

- `azure_credentials`: JSON (or compatible) fields `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_CLIENT_SECRET` for read-only ARM access to NSGs and related network resources. Grant **Reader** (or equivalent) on the subscription or resource group.

## Tasks overview

### Export Live NSG Rules for Comparison

Runs `nsg-export-live-rules.sh` to build `nsg_live_bundle.json` and may raise issues if login fails, an NSG cannot be read, or none match the filter.

### Load and Normalize Baseline NSG Definition

Runs `nsg-load-baseline.sh` to produce `nsg_baseline_bundle.json`. Issues indicate a missing path, invalid JSON, or unsupported layout.

### Diff Live vs Baseline and Report Drift

Runs `nsg-diff-desired-state.sh` using `nsg_live_bundle.json` and `nsg_baseline_bundle.json`. Issues cover missing NSGs in the baseline, extra or removed rules, and changed rule bodies.

### Validate Subnet and NIC NSG Associations

Runs `nsg-association-audit.sh` for association inventory and optional comparison to `ASSOCIATION_BASELINE_PATH`.

### Summarize Drift Scope for Operators

Runs `nsg-drift-summary.sh` to emit a rollup issue and human-readable portal links from the live export.

## Baseline format

The canonical bundle shape is:

```json
{
  "schemaVersion": "1",
  "nsgs": [
    {
      "name": "my-nsg",
      "resourceGroup": "my-rg",
      "id": "/subscriptions/.../networkSecurityGroups/my-nsg",
      "securityRules": [],
      "defaultSecurityRules": []
    }
  ]
}
```

Each NSG object may be a raw `az network nsg show -o json` document; the load script normalizes fields. For a quick baseline, run the export task once in a known-good environment and commit the resulting `nsg_live_bundle.json` as your golden file.
