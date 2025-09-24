# RunWhen Generation Rules and Templates

This directory contains the RunWhen platform generation rules and templates for the `azure-dns-health` codebundle.

## Directory Structure

```
.runwhen/
├── generation-rules/
│   └── azure-dns-health.yaml      # Generation rules and triggers
├── templates/
│   ├── runbook-slx.yaml           # Runbook SLX template
│   ├── sli-slx.yaml               # SLI SLX template
│   └── discovery-config.yaml      # Auto-discovery configuration
└── README.md                      # This file
```

## Generation Rules

### File: `generation-rules/azure-dns-health.yaml`

Defines when and how to generate SLX objects for Azure DNS health monitoring:

- **Auto-discovery**: Automatically discovers Azure DNS zones, private DNS zones, and DNS resolvers
- **Trigger patterns**: DNS resolution failures, NXDOMAIN errors, Azure DNS service errors
- **Severity levels**: Critical, high, medium for different types of issues
- **Resource matching**: Maps Azure resource types to codebundle variables
- **Scheduling**: Defines execution intervals and timeouts

## Templates

### Runbook SLX Template: `templates/runbook-slx.yaml`

Creates comprehensive DNS health runbooks with:
- **Auto-discovery integration**: Uses discovered Azure DNS resources
- **Environment variables**: Pre-configured with Azure subscription and resource context
- **Trigger conditions**: Alert-based, manual, and scheduled execution
- **Notification settings**: Slack integration for success/failure notifications
- **Resource context**: Azure subscription, resource group, and DNS zone information

### SLI SLX Template: `templates/sli-slx.yaml`

Creates lightweight DNS health SLIs with:
- **Metrics collection**: DNS resolution success rate, query latency, zone health, resolver availability
- **Service Level Objectives**: 99.9% availability, <500ms latency, healthy zone status
- **Alert thresholds**: Critical, warning, and info level alerts
- **Integration settings**: Prometheus, Grafana, and Azure Monitor integration
- **Fast execution**: 5-minute intervals with 2-minute timeouts

### Discovery Configuration: `templates/discovery-config.yaml`

Configures auto-discovery for Azure DNS resources:
- **Resource types**: Public DNS zones, private DNS zones, DNS resolvers
- **Discovery rules**: Conditions for generating SLX objects
- **Variable mapping**: Maps discovered properties to template variables
- **Aggregation rules**: Creates resource group and subscription level SLX objects

## Usage

### Automatic Generation

The RunWhen platform automatically uses these rules to:

1. **Discover Azure DNS resources** in your subscriptions
2. **Generate SLX objects** based on discovered resources and trigger patterns
3. **Deploy monitoring** for each DNS zone and resolver
4. **Create alerts** when DNS issues are detected

### Manual Generation

You can also manually generate SLX objects using the RunWhen CLI:

```bash
# Generate SLX objects for a specific resource group
runwhen generate --codebundle azure-dns-health \
  --resource-group myapp-dns \
  --subscription-id 12345678-1234-1234-1234-123456789012

# Generate with custom variables
runwhen generate --codebundle azure-dns-health \
  --template runbook-slx.yaml \
  --vars ResourceGroup=myapp-dns,DNSZone=myapp.com,SubscriptionId=12345678-1234-1234-1234-123456789012
```

## Template Variables

### Common Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `ResourceGroup` | Azure resource group name | `myapp-dns` |
| `DNSZone` | DNS zone name | `myapp.com` |
| `SubscriptionId` | Azure subscription ID | `12345678-1234-1234-1234-123456789012` |
| `ZoneType` | Zone type (public/private) | `public` |
| `Location` | Azure region | `eastus` |

### Auto-Discovery Variables

| Variable | Description | Source |
|----------|-------------|--------|
| `TestFQDNs` | FQDNs to test | `discovery.suggested_test_fqdns` |
| `PublicDomains` | Public DNS zones | `discovery.public_dns_zones` |
| `ForwardLookupZones` | Forward lookup zones | `discovery.forward_lookup_zones` |
| `ExpressRouteZones` | Express Route DNS zones | `discovery.express_route_zones` |
| `DNSResolvers` | DNS resolver IPs | `discovery.dns_resolvers` |

## Customization

### Adding New Trigger Patterns

Edit `generation-rules/azure-dns-health.yaml`:

```yaml
triggers:
  - pattern: "your.*custom.*pattern"
    severity: high
    description: "Your custom DNS issue"
```

### Modifying Templates

1. **Edit template files** in the `templates/` directory
2. **Use Go template syntax** for variable substitution
3. **Test templates** with sample data before deployment

### Custom Discovery Rules

Edit `templates/discovery-config.yaml`:

```yaml
discovery_rules:
  - name: "custom_rule"
    resource_type: "Microsoft.Network/dnsZones"
    template: "runbook-slx.yaml"
    conditions:
      - property: "customProperty"
        operator: "equals"
        value: "customValue"
```

## Integration

### With Auto-Discovery

The templates automatically integrate with the codebundle's auto-discovery functionality:

1. **Discovery script** (`azure_dns_auto_discovery.sh`) finds Azure DNS resources
2. **Generation rules** create SLX objects for discovered resources
3. **Templates** populate variables from discovery results
4. **SLX objects** are deployed with proper Azure context

### With Monitoring Systems

Generated SLX objects integrate with:

- **Prometheus**: Metrics collection and storage
- **Grafana**: Visualization and dashboards
- **Azure Monitor**: Native Azure monitoring integration
- **Slack**: Notification and alerting
- **Email**: Critical alert notifications

## Best Practices

1. **Use auto-discovery**: Let the platform discover resources automatically
2. **Customize templates**: Adapt templates to your specific requirements
3. **Monitor generation**: Review generated SLX objects for accuracy
4. **Update patterns**: Keep trigger patterns current with observed issues
5. **Test thoroughly**: Validate templates with sample data before production use
