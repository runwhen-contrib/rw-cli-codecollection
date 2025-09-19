# Azure DNS Health Test Directory

This directory contains test configurations, scripts, and sample data for testing the Azure DNS Health codebundle.

## Directory Structure

```
.test/
├── configs/           # Test configuration files
├── scripts/          # Test scripts
├── sample-data/      # Sample data files
└── docs/            # Documentation
```

## Test Configurations

### Basic Test (`basic-test.yaml`)
- Tests basic DNS resolution for private endpoints
- Minimal configuration for quick testing
- Expected metrics: 100% success rate, <100ms latency

### Forward Lookup Test (`forward-lookup-test.yaml`)
- Tests forward lookup zones and conditional forwarders
- Tests subdomains in forward lookup zones
- Tests specific DNS resolvers

### Public Zones Test (`public-zones-test.yaml`)
- Tests public DNS zones and external resolution
- Tests external domains and upstream forwarding
- Tests external resolvers

### Express Route Test (`express-route-test.yaml`)
- Tests DNS resolution through Express Route
- Tests DNS server connectivity
- Monitors latency and packet drops

### Comprehensive Test (`comprehensive-test.yaml`)
- Tests all DNS health monitoring features
- Multiple resource groups and FQDN types
- Complete DNS health picture

## Test Scripts

### `test-dns-resolution.sh`
- Tests DNS resolution for configured FQDNs
- Tests with specific resolvers
- Measures DNS latency
- Provides colored output for easy reading

### `test-azure-dns.sh`
- Tests Azure CLI authentication
- Tests resource groups and DNS zones
- Tests VNets and network configuration
- Validates Azure environment setup

### `run-tests.sh`
- Runs all test configurations
- Supports running specific tests
- Lists available tests
- Provides help and usage information

## Sample Data

### `sample-fqdns.txt`
- Sample FQDNs for testing
- Azure Private Link FQDNs
- Azure App Service FQDNs
- Public DNS FQDNs
- Internal/Corporate FQDNs

### `sample-resource-groups.txt`
- Sample resource groups for testing
- Production, staging, and development environments
- Network-specific resource groups
- Application-specific resource groups

### `sample-dns-resolvers.txt`
- Sample DNS resolvers for testing
- Public DNS resolvers (Google, Cloudflare, Quad9)
- Azure DNS resolvers
- Corporate DNS resolvers

## Usage

### Running All Tests
```bash
cd .test
./scripts/run-tests.sh
```

### Running Specific Test
```bash
cd .test
./scripts/run-tests.sh basic-test
```

### Testing DNS Resolution
```bash
cd .test
./scripts/test-dns-resolution.sh
```

### Testing Azure DNS
```bash
cd .test
./scripts/test-azure-dns.sh
```

### Listing Available Tests
```bash
cd .test
./scripts/run-tests.sh --list
```

## Prerequisites

- Azure CLI installed and configured
- Access to Azure subscription
- Network connectivity to DNS servers
- Bash shell environment
- Basic Unix utilities (nslookup, grep, etc.)

## Configuration

### Environment Variables
- `RESOURCE_GROUPS`: Comma-separated list of resource groups
- `TEST_FQDNS`: Comma-separated list of FQDNs to test
- `FORWARD_LOOKUP_ZONES`: Comma-separated list of forward lookup zones
- `PUBLIC_ZONES`: Comma-separated list of public zones
- `DNS_RESOLVERS`: Comma-separated list of DNS resolvers

### Test Configuration Files
Each test configuration is a YAML file with variables section:
```yaml
variables:
  RESOURCE_GROUPS: "production-rg,network-rg"
  TEST_FQDNS: "myapp.privatelink.database.windows.net"
  # ... other variables
```

## Expected Results

### Basic Test
- DNS Resolution Success Rate: 100%
- DNS Query Latency: <100ms
- Private DNS Zone Health: 1 (healthy)
- External DNS Resolver Availability: 100%

### Forward Lookup Test
- Tests forward lookup zones
- Tests subdomains
- Tests specific resolvers
- Detects forward lookup zone configuration

### Public Zones Test
- Tests public zones
- Tests external domains
- Tests external resolvers
- Validates external DNS resolution

### Express Route Test
- Tests Express Route DNS zones
- Tests DNS server connectivity
- Monitors latency
- Detects route congestion

### Comprehensive Test
- Tests all features
- Multiple resource groups
- Various FQDN types
- Complete DNS health picture

## Troubleshooting

### Common Issues
1. **Azure CLI not authenticated**: Run `az login`
2. **Resource groups not found**: Check resource group names
3. **DNS resolution failures**: Check network connectivity
4. **Script permissions**: Run `chmod +x scripts/*.sh`

### Debug Information
- Test scripts provide colored output
- Detailed error messages
- Configuration validation
- Step-by-step execution

## Contributing

To add new test configurations:
1. Create new YAML file in `configs/` directory
2. Follow existing format with variables section
3. Add descriptive comments
4. Test the configuration

To add new test scripts:
1. Create new shell script in `scripts/` directory
2. Make executable with `chmod +x`
3. Follow existing patterns for output and error handling
4. Add documentation
