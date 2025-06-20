# Azure VM Disk Health Check

This codebundle provides tools to monitor and check disk utilization on Azure Virtual Machines. It helps identify VMs with high disk usage that might need attention.

## Features

- Checks disk utilization on Azure VMs
- Generates health scores based on disk usage
- Provides detailed information about VMs and their attached disks
- Raises issues when disk usage exceeds defined thresholds

## Tasks

- `Check Disk Utilization for VM`: Checks disk utilization and reports issues if usage exceeds threshold

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `AZ_RESOURCE_GROUP`: The resource group containing the VM(s)
- `VM_NAME`: (Optional) The Azure Virtual Machine to check. Leave empty to check all VMs in the resource group
- `DISK_THRESHOLD`: The threshold percentage for disk usage warnings (default: 80)
- `AZURE_SUBSCRIPTION_ID`: The Azure Subscription ID

## SLI

The SLI generates a health score based on disk utilization:
- 1.0 = All disks are healthy (below threshold)
- 0.0 = All disks are unhealthy (above threshold)
- Values between 0 and 1 represent the proportion of healthy disks

## Prerequisites

- Azure CLI must be installed and configured
- Appropriate permissions to access and run commands on Azure VMs
- Service principal with appropriate permissions

## Usage

This codebundle can be used to:
1. Monitor disk utilization across all VMs in a resource group
2. Focus on a specific VM by providing its name
3. Adjust the threshold for disk usage warnings
