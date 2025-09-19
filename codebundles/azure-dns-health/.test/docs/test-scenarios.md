# DNS Health Test Scenarios

This document describes various test scenarios for the Azure DNS Health codebundle.

## Test Scenario 1: Basic DNS Health Monitoring

### Objective
Test basic DNS resolution for private endpoints in a production environment.

### Configuration
```yaml
variables:
  RESOURCE_GROUPS: "production-rg,network-rg"
  TEST_FQDNS: "myapp.privatelink.database.windows.net,myapi.privatelink.azurewebsites.net"
```

### Expected Results
- DNS Resolution Success Rate: 100%
- DNS Query Latency: <100ms
- Private DNS Zone Health: 1 (healthy)
- External DNS Resolver Availability: 100%

### Test Steps
1. Run basic test configuration
2. Verify all FQDNs resolve successfully
3. Check latency is within acceptable range
4. Validate private DNS zone health
5. Test external resolver availability

## Test Scenario 2: Forward Lookup Zone Testing

### Objective
Test forward lookup zones and conditional forwarders for internal domains.

### Configuration
```yaml
variables:
  RESOURCE_GROUPS: "production-rg,network-rg"
  TEST_FQDNS: "myapp.privatelink.database.windows.net"
  FORWARD_LOOKUP_ZONES: "internal.company.com,corp.local"
  FORWARD_ZONE_TEST_SUBDOMAINS: "dc01,mail,web"
  DNS_RESOLVERS: "8.8.8.8,1.1.1.1,10.0.0.4"
```

### Expected Results
- Forward lookup zones resolve correctly
- Subdomains resolve through forward lookup zones
- Specific resolvers work as expected
- Conditional forwarders are properly configured

### Test Steps
1. Test forward lookup zones: internal.company.com, corp.local
2. Test subdomains: dc01.internal.company.com, mail.internal.company.com, web.internal.company.com
3. Test specific resolvers: 8.8.8.8, 1.1.1.1, 10.0.0.4
4. Verify forward lookup zone configuration

## Test Scenario 3: Public DNS Zone Testing

### Objective
Test public DNS zones and external resolution through multiple resolvers.

### Configuration
```yaml
variables:
  RESOURCE_GROUPS: "production-rg,network-rg"
  TEST_FQDNS: "myapp.privatelink.database.windows.net"
  PUBLIC_ZONES: "example.com,mycompany.com"
  PUBLIC_DOMAINS: "google.com,github.com"
  DNS_RESOLVERS: "8.8.8.8,1.1.1.1"
```

### Expected Results
- Public zones resolve correctly
- External domains resolve through multiple resolvers
- External resolver availability is 100%
- Upstream forwarding works correctly

### Test Steps
1. Test public zones: example.com, mycompany.com
2. Test external domains: google.com, github.com
3. Test external resolvers: 8.8.8.8, 1.1.1.1
4. Validate external DNS resolution

## Test Scenario 4: Express Route DNS Testing

### Objective
Test DNS resolution through Express Route and monitor for latency issues.

### Configuration
```yaml
variables:
  RESOURCE_GROUPS: "production-rg"
  TEST_FQDNS: "myapp.privatelink.database.windows.net"
  EXPRESS_ROUTE_DNS_ZONES: "internal.company.com,corp.company.com"
  DNS_SERVER_IPS: "10.0.0.4,10.0.1.4"
  FORWARD_LOOKUP_ZONES: "internal.company.com"
```

### Expected Results
- Express Route DNS zones resolve correctly
- DNS server connectivity is maintained
- Latency is within acceptable range
- No packet drops detected

### Test Steps
1. Test Express Route DNS zones: internal.company.com, corp.company.com
2. Test DNS server connectivity: 10.0.0.4, 10.0.1.4
3. Monitor latency through Express Route
4. Check for packet drops

## Test Scenario 5: Comprehensive DNS Health Testing

### Objective
Test all DNS health monitoring features in a comprehensive manner.

### Configuration
```yaml
variables:
  RESOURCE_GROUPS: "production-rg,network-rg,staging-rg"
  TEST_FQDNS: "myapp.privatelink.database.windows.net,myapi.privatelink.azurewebsites.net,myapp.privatelink.blob.core.windows.net"
  FORWARD_LOOKUP_ZONES: "internal.company.com,corp.local"
  PUBLIC_ZONES: "example.com,mycompany.com"
  PUBLIC_DOMAINS: "google.com,github.com,stackoverflow.com"
  DNS_RESOLVERS: "8.8.8.8,1.1.1.1,10.0.0.4,10.0.1.4"
  EXPRESS_ROUTE_DNS_ZONES: "internal.company.com,corp.company.com"
  FORWARD_ZONE_TEST_SUBDOMAINS: "dc01,mail,web,api"
  DNS_SERVER_IPS: "10.0.0.4,10.0.1.4,8.8.8.8"
```

### Expected Results
- All DNS health metrics are within acceptable ranges
- Multiple resource groups are monitored
- Various FQDN types are tested
- Complete DNS health picture is provided

### Test Steps
1. Test multiple resource groups
2. Test various FQDN types (database, app service, blob storage)
3. Test forward lookup zones with subdomains
4. Test public zones and external domains
5. Test multiple DNS resolvers
6. Test Express Route DNS zones
7. Test DNS server connectivity

## Test Scenario 6: Failure Testing

### Objective
Test DNS health monitoring when DNS resolution fails.

### Configuration
```yaml
variables:
  RESOURCE_GROUPS: "production-rg"
  TEST_FQDNS: "nonexistent.domain.com,invalid.fqdn.test"
  PUBLIC_ZONES: "nonexistent.zone.com"
  DNS_RESOLVERS: "192.168.1.999,10.0.0.999"
```

### Expected Results
- DNS Resolution Success Rate: 0%
- DNS Query Latency: High or timeout
- Private DNS Zone Health: 0 (unhealthy)
- External DNS Resolver Availability: 0%

### Test Steps
1. Test with non-existent FQDNs
2. Test with invalid DNS resolvers
3. Verify failure detection
4. Check error reporting

## Test Scenario 7: Performance Testing

### Objective
Test DNS health monitoring under high load and performance conditions.

### Configuration
```yaml
variables:
  RESOURCE_GROUPS: "production-rg,network-rg,staging-rg,dev-rg"
  TEST_FQDNS: "myapp1.privatelink.database.windows.net,myapp2.privatelink.database.windows.net,myapp3.privatelink.database.windows.net,myapp4.privatelink.database.windows.net,myapp5.privatelink.database.windows.net"
  PUBLIC_DOMAINS: "google.com,github.com,stackoverflow.com,microsoft.com,azure.com"
  DNS_RESOLVERS: "8.8.8.8,1.1.1.1,9.9.9.9,149.112.112.112"
```

### Expected Results
- Performance remains stable under load
- Latency stays within acceptable range
- No timeouts or failures
- Efficient resource usage

### Test Steps
1. Test with multiple resource groups
2. Test with multiple FQDNs
3. Test with multiple external domains
4. Test with multiple resolvers
5. Monitor performance metrics

## Test Scenario 8: Network Connectivity Testing

### Objective
Test DNS health monitoring when network connectivity is limited.

### Configuration
```yaml
variables:
  RESOURCE_GROUPS: "production-rg"
  TEST_FQDNS: "myapp.privatelink.database.windows.net"
  DNS_RESOLVERS: "10.0.0.4"
  PUBLIC_DOMAINS: "google.com"
```

### Expected Results
- Internal DNS resolution works
- External DNS resolution may fail
- Network connectivity issues are detected
- Appropriate error reporting

### Test Steps
1. Test with internal resolvers only
2. Test external domain resolution
3. Verify network connectivity detection
4. Check error reporting

## Test Scenario 9: Azure Environment Testing

### Objective
Test DNS health monitoring in different Azure environments.

### Configuration
```yaml
variables:
  RESOURCE_GROUPS: "production-rg,staging-rg,dev-rg"
  TEST_FQDNS: "myapp.privatelink.database.windows.net"
  FORWARD_LOOKUP_ZONES: "internal.company.com"
  PUBLIC_ZONES: "mycompany.com"
```

### Expected Results
- Different environments are tested
- Environment-specific configurations work
- Cross-environment DNS resolution works
- Environment isolation is maintained

### Test Steps
1. Test production environment
2. Test staging environment
3. Test development environment
4. Test cross-environment resolution

## Test Scenario 10: Monitoring Integration Testing

### Objective
Test DNS health monitoring integration with monitoring systems.

### Configuration
```yaml
variables:
  RESOURCE_GROUPS: "production-rg"
  TEST_FQDNS: "myapp.privatelink.database.windows.net"
  FORWARD_LOOKUP_ZONES: "internal.company.com"
  PUBLIC_ZONES: "mycompany.com"
  DNS_RESOLVERS: "8.8.8.8,1.1.1.1"
```

### Expected Results
- Metrics are properly collected
- Alerts are triggered appropriately
- Monitoring integration works
- Data is properly formatted

### Test Steps
1. Test metric collection
2. Test alert triggering
3. Test monitoring integration
4. Verify data formatting
