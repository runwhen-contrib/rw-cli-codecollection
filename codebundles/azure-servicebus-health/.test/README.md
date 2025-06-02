export SB_NAMESPACE_NAME=sb-demo-primary

# Azure Service Bus Health Test Environment

This directory contains scripts and configurations for testing the Azure Service Bus Health codebundle.

## Prerequisites

- Azure CLI installed and authenticated
- Terraform (for infrastructure creation)
- Docker (for RunWhen Local)
- Task (go-task) - for task execution

## Quick Start

To build the infrastructure, prepare test data, run tests, and then clean up:

```bash
task run-with-test-data
```

## Test Components

### Infrastructure

The test infrastructure is created using Terraform:

```bash
cd terraform
task build-terraform-infra
```

To destroy the infrastructure:

```bash
cd terraform
task destroy-terraform-infra
```

### Test Data Generation

After creating the infrastructure, you can prepare test data to simulate various scenarios:

1. Inject messages into queues and topics:
   ```bash
   task inject-test-messages
   ```

2. Configure security test scenarios:
   ```bash
   task configure-security-test
   ```

3. Generate traffic to produce metrics:
   ```bash
   task generate-traffic
   ```

4. Generate activity for Log Analytics:
   ```bash
   task generate-log-activity
   ```

5. Setup connectivity test scenarios:
   ```bash
   task setup-connectivity-test
   ```

To run all test data preparation tasks:
```bash
task prepare-test-data
```

### Running Tests

To run the RunWhen Local discovery against the test infrastructure:

```bash
task run-rwl-discovery
```

### Cleaning Up

To clean up generated files and configurations:

```bash
task clean
```

## Environment Variables

- `SB_NAMESPACE_NAME`: Name of the Service Bus namespace (default: sb-demo-primary)
- `AZ_RESOURCE_GROUP`: Name of the resource group (fetched from Terraform)
- `DURATION_MINUTES`: Duration for traffic generation (default: 15)
- `INTENSITY`: Traffic generation intensity - low, medium, high (default: medium)