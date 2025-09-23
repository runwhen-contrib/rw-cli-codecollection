# Azure DNS Health Monitoring

This codebundle provides comprehensive DNS health monitoring for Azure environments, including resolution success rates, latency measurements, and availability of DNS services across multiple VNets, zones, and FQDNs.

## Features

- **DNS Resolution Success Rate**: Measures the success rate of DNS resolution across configured FQDNs
- **DNS Query Latency**: Measures average DNS query latency in milliseconds
- **Private DNS Zone Health**: Monitors the health of private DNS zones across resource groups
- **External DNS Resolver Availability**: Tests availability of external DNS resolvers
- **Forward Lookup Zone Testing**: Tests forward lookup zones and conditional forwarders
- **Public Zone Testing**: Tests public DNS zones for external resolution
- **Express Route Latency Monitoring**: Monitors DNS query latency through Express Route

## Configuration Variables

### Required Variables

- **`RESOURCE_GROUPS`**: Comma-separated list of Azure resource groups containing DNS zones and VNets
  - Example: `my-plink-rg,production-rg,network-rg`

- **`TEST_FQDNS`**: Comma-separated list of FQDNs to test for DNS resolution
  - Example: `myapp.privatelink.database.windows.net,myapi.privatelink.azurewebsites.net`

### Optional Variables

- **`FORWARD_LOOKUP_ZONES`**: Comma-separated list of forward lookup zones to test
  - Example: `internal.company.com,corp.local`
  - Default: Empty

- **`PUBLIC_ZONES`**: Comma-separated list of public DNS zones to test
  - Example: `example.com,mycompany.com`
  - Default: Empty

- **`DNS_RESOLVERS`**: Comma-separated list of specific DNS resolvers to test against
  - Example: `8.8.8.8,1.1.1.1,10.0.0.4`
  - Default: Empty (uses default external resolvers)

- **`PUBLIC_DOMAINS`**: Comma-separated list of public domains for external resolution validation
  - Example: `example.com,mycompany.com`
  - Default: Empty

- **`EXPRESS_ROUTE_DNS_ZONES`**: Comma-separated list of DNS zones accessed through Express Route for latency testing
  - Example: `internal.company.com,corp.company.com`
  - Default: Empty

- **`FORWARD_ZONE_TEST_SUBDOMAINS`**: Comma-separated list of subdomains to test in forward lookup zones
  - Example: `dc01,mail,web`
  - Default: Empty


## SLI Tasks

### DNS Resolution Success Rate
Measures the success rate of DNS resolution across all configured FQDNs and pushes a metric (0-100).

**Tags**: `azure`, `dns`, `resolution`, `success-rate`, `sli`

### DNS Query Latency
Measures average DNS query latency in milliseconds across all configured FQDNs and pushes the metric.

**Tags**: `azure`, `dns`, `latency`, `performance`, `sli`

### Private DNS Zone Health
Measures the health of private DNS zones across multiple resource groups (1 for healthy, 0 for unhealthy).

**Tags**: `azure`, `dns`, `private-dns`, `zone-health`, `sli`

### External DNS Resolver Availability
Measures availability of external DNS resolvers (percentage of working resolvers).

**Tags**: `azure`, `dns`, `external`, `resolver`, `availability`, `sli`

## Runbook Tasks

### Check Private DNS Zone Records
Verifies record counts and integrity for private DNS zones in the specified resource group(s).

**Tags**: `azure`, `dns`, `private-dns`, `zone-records`

### Check Public DNS Zone Records
Verifies record counts and integrity for public DNS zones in the specified resource group(s).

**Tags**: `azure`, `dns`, `public-dns`, `zone-records`


### Detect Broken Record Resolution
Implements repeated pull/flush/pull DNS checks for multiple FQDNs to detect failures before TTL expiry.

**Tags**: `azure`, `dns`, `resolution`, `consistency`

### Test Forward Lookup Zones
Tests forward lookup zones and conditional forwarders for proper resolution.

**Tags**: `azure`, `dns`, `forward-lookup`, `conditional-forwarders`

### External Resolution Validation
Tests resolution of multiple public and private hosted domains through multiple resolvers, testing upstream forwarding.

**Tags**: `azure`, `dns`, `external`, `public`, `resolvers`

### Express Route Latency and Saturation Check
Alerts if DNS queries through multiple forwarded zones show high latency or packet drops, indicating possible route congestion.

**Tags**: `azure`, `dns`, `express-route`, `latency`, `performance`

## Usage Examples

### Basic DNS Health Monitoring
```yaml
variables:
  RESOURCE_GROUPS: "production-rg,network-rg"
  TEST_FQDNS: "myapp.privatelink.database.windows.net,myapi.privatelink.azurewebsites.net"
```

### Advanced DNS Testing with Forward Lookup Zones
```yaml
variables:
  RESOURCE_GROUPS: "production-rg,network-rg"
  TEST_FQDNS: "myapp.privatelink.database.windows.net"
  FORWARD_LOOKUP_ZONES: "internal.company.com,corp.local"
  PUBLIC_ZONES: "example.com,mycompany.com"
  DNS_RESOLVERS: "8.8.8.8,1.1.1.1,10.0.0.4"
```

### Express Route DNS Monitoring
```yaml
variables:
  RESOURCE_GROUPS: "production-rg"
  TEST_FQDNS: "myapp.privatelink.database.windows.net"
  EXPRESS_ROUTE_DNS_ZONES: "internal.company.com,corp.company.com"
```

## Prerequisites

- Azure CLI configured with appropriate permissions
- Access to the specified resource groups
- Network connectivity to DNS servers and external resolvers

## Metrics

The codebundle pushes the following metrics:

- **DNS Resolution Success Rate**: Percentage (0-100) of successful DNS resolutions
- **DNS Query Latency**: Average latency in milliseconds
- **Private DNS Zone Health**: Binary health indicator (1 = healthy, 0 = unhealthy)
- **External DNS Resolver Availability**: Percentage (0-100) of working external resolvers

## Troubleshooting

### Common Issues

1. **DNS Resolution Failures**: Check DNS configuration and private DNS zone links
2. **High Latency**: Monitor Express Route performance and DNS forwarder configuration
3. **Empty DNS Zones**: Verify DNS zone configuration and record sets
4. **External Resolution Issues**: Check DNS forwarder configuration and upstream connectivity

### Debug Information

The codebundle provides detailed debug information including:
- Command outputs and results
- DNS resolution test results
- Zone health status
- Latency measurements
- Error messages and troubleshooting steps
