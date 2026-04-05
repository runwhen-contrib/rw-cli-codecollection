# Azure Subnet Egress Path Validation

This CodeBundle validates that egress from subnets in an Azure virtual network matches intent: subnet attachments (NSGs, route tables), effective NSG egress posture, optional forced tunneling via firewall or NVA, and optional connectivity probes using Azure Network Watcher.

## Overview

- **Discovery**: Lists subnets in the VNet scope and resolves subnet IDs, attached NSGs, and route tables.
- **NSG egress**: Reviews outbound NSG rules at subnet scope and flags common posture gaps for follow-up.
- **Routes / firewall**: Evaluates route tables for default routes toward a firewall or NVA when `REQUIRE_DEFAULT_ROUTE_VIA_FIREWALL` is enabled; notes subnets without a custom route table.
- **Probes**: Runs Network Watcher connection tests when `PROBE_MODE=network-watcher` and `SOURCE_VM_RESOURCE_ID` is set; supports `bastion-agent` and `skip-probes` modes for environments where automated probes are not possible.
- **Summary**: Merges JSON findings from prior steps and prints a concise matrix to the report.

## Configuration

### Required Variables

- `AZURE_SUBSCRIPTION_ID`: Azure subscription ID containing the VNet.
- `AZURE_RESOURCE_GROUP`: Resource group that contains the virtual network.
- `VNET_NAME`: Virtual network name to analyze.
- `PROBE_TARGETS`: Comma-separated probe targets (`host:port` or URLs such as `https://example.com:443`) used when probe mode runs Network Watcher tests.

### Optional Variables

- `PROBE_MODE`: `network-watcher` (default), `bastion-agent`, or `skip-probes` for rules-only validation.
- `SOURCE_VM_RESOURCE_ID`: Resource ID of a VM in the target subnet for Network Watcher connection troubleshoot (required for automated probes in `network-watcher` mode).
- `SUBNET_NAME_FILTER`: Comma-separated subnet names to limit analysis (empty includes all subnets).
- `REQUIRE_DEFAULT_ROUTE_VIA_FIREWALL`: When `true`, each subnet with a route table must have a `0.0.0.0/0` route with `nextHopType` `VirtualAppliance` or `Firewall`.
- `TIMEOUT_SECONDS`: Timeout for bash tasks in seconds (default `300`).

### Secrets

- `azure_credentials`: Service principal JSON or equivalent used by Azure CLI (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_CLIENT_SECRET`, and subscription context as required by your environment). Network Watcher connection tests typically require additional permissions (for example Network Contributor) beyond read-only resource access.

## Tasks Overview

### Discover Subnets and Attached NSGs for VNet

Enumerates subnets and resolves NSG and route table IDs. Raises issues when the VNet cannot be read or no subnets match filters.

### Summarize Effective Egress Rules per Subnet

Lists outbound NSG rules for subnet-associated NSGs and flags patterns that may need policy review (for example, no subnet-level NSG).

### Validate Route Table and Firewall Next Hop

Checks route tables for required default routes when forced tunneling is mandated; flags subnets without an associated route table.

### Run Connectivity Probes for Egress Targets

Uses `az network watcher connection-test` when a source VM is provided; otherwise documents limitations per `PROBE_MODE`.

### Report Egress Validation Summary for VNet

Combines issue JSON from earlier tasks and prints counts per stage for operator review.
