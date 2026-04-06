# Azure Subnet Egress Path Validation

This CodeBundle inspects Azure virtual network subnets to validate egress-related configuration: subnet-attached NSGs (outbound rules), route tables and default routes relative to Azure Firewall, optional Network Watcher connectivity probes from a designated VM, and a merged summary matrix.

## Overview

- **Discovery**: Lists subnets under a VNet and resolves attached NSG and route table resource IDs.
- **NSG egress**: Summarizes outbound NSG rules per subnet-attached NSG and flags subnets without an NSG.
- **Routes and firewall**: Evaluates UDR default routes (`0.0.0.0/0`) when an Azure Firewall exists in the same resource group and warns on Internet bypass patterns.
- **Probes**: Optional `az network watcher test-connectivity` runs from `SOURCE_VM_RESOURCE_ID` to each `PROBE_TARGETS` entry, or skips/bastion placeholder modes.
- **Summary**: Merges issue JSON from prior steps and emits a structured matrix (`subnet_summary_matrix.json`).

## Configuration

### Required variables

- `AZURE_SUBSCRIPTION_ID`: Azure subscription ID containing the VNet.
- `AZURE_RESOURCE_GROUP`: Resource group that holds the virtual network.
- `VNET_NAME`: Name of the virtual network to analyze.
- `PROBE_TARGETS`: Comma-separated destinations for probes, for example `https://example.com:443`, `http://example.com:80`, or `example.com:443`.

### Optional variables

- `PROBE_MODE`: `network-watcher` (default), `bastion-agent` (manual guidance only), or `skip-probes` (rules-only).
- `SOURCE_VM_RESOURCE_ID`: Azure resource ID of a VM in the target subnet; required for `network-watcher` probes.

### Secrets

- `azure_credentials`: JSON or workspace mapping with `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_CLIENT_SECRET`, and typically `AZURE_SUBSCRIPTION_ID`. Network Watcher connectivity tests may require additional RBAC (for example Network Contributor) beyond Reader.

## Tasks overview

### Discover Subnets and Attached NSGs in Scope for VNet

Lists subnets and resolves NSG and route table IDs; raises issues if the VNet cannot be read or has no subnets.

### Summarize Effective Egress Rules per Subnet for VNet

Aggregates outbound NSG rules per subnet NSG and warns when a subnet has no NSG attached.

### Validate Route Table and Firewall Next Hop for VNet

Checks route tables for a default route and compares with Azure Firewall presence in the resource group.

### Run Connectivity Probes for Egress Targets from VNet

Runs Network Watcher tests per target, or skips/bastion modes per `PROBE_MODE`.

### Report Egress Validation Summary for VNet

Merges prior step issue files and prints a subscription/VNet matrix with probe results when available.
