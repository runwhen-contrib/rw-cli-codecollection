## Foundation

resource "azurerm_resource_group" "sb_rg" {
  name     = var.resource_group
  location = var.location
}

resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-sb-demo"
  address_space       = ["10.50.0.0/20"]
  location            = azurerm_resource_group.sb_rg.location
  resource_group_name = azurerm_resource_group.sb_rg.name
}

resource "azurerm_subnet" "subnet_pe" {
  name                 = "snet-sb-pe"
  resource_group_name  = azurerm_resource_group.sb_rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.50.1.0/24"]
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-sb-health-demo"
  location            = azurerm_resource_group.sb_rg.location
  resource_group_name = azurerm_resource_group.sb_rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

### Service Bus

resource "azurerm_servicebus_namespace" "primary" {
  name                          = "sb-demo-primary"
  location                      = azurerm_resource_group.sb_rg.location
  resource_group_name           = azurerm_resource_group.sb_rg.name
  sku                           = "Premium"
  capacity                      = 1
  minimum_tls_version           = "1.2"
  premium_messaging_partitions  = 1
  public_network_access_enabled = false # forces PE test
  identity {
    type = "SystemAssigned"
  }
}

### Entities for Metrics

resource "azurerm_servicebus_queue" "orders" {
  name                                    = "orders-queue"
  namespace_id                            = azurerm_servicebus_namespace.primary.id
  dead_lettering_on_message_expiration    = true
  auto_delete_on_idle                     = "P14D" # 14 days
  max_delivery_count                      = 10
  requires_duplicate_detection            = true
  duplicate_detection_history_time_window = "PT10M"
}

resource "azurerm_servicebus_topic" "billing" {
  name         = "billing-topic"
  namespace_id = azurerm_servicebus_namespace.primary.id
}

resource "azurerm_servicebus_subscription" "billing_dlq" {
  name                                 = "deadletter"
  topic_id                             = azurerm_servicebus_topic.billing.id
  max_delivery_count                   = 5
  dead_lettering_on_message_expiration = true
}


## Diagnostic settings → Log Analytics

resource "azurerm_monitor_diagnostic_setting" "sb_diag" {
  name                       = "diag-to-law"
  target_resource_id         = azurerm_servicebus_namespace.primary.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id

  enabled_log {
    category = "OperationalLogs"
  }
  enabled_log {
    category = "RuntimeAuditLogs"
  }
  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

## Private-endpoint access path

resource "azurerm_private_endpoint" "sb_pe" {
  name                = "pe-sb-demo"
  location            = azurerm_resource_group.sb_rg.location
  resource_group_name = azurerm_resource_group.sb_rg.name
  subnet_id           = azurerm_subnet.subnet_pe.id

  private_service_connection {
    name                           = "psc-sb"
    private_connection_resource_id = azurerm_servicebus_namespace.primary.id
    is_manual_connection           = false
    subresource_names              = ["namespace"]
  }
}

resource "azurerm_private_dns_zone" "sb_dns" {
  name                = "privatelink.servicebus.windows.net"
  resource_group_name = azurerm_resource_group.sb_rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "dns_link" {
  name                  = "vnet-link"
  resource_group_name   = azurerm_resource_group.sb_rg.name
  private_dns_zone_name = azurerm_private_dns_zone.sb_dns.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

## Geo-DR pair (secondary namespace + alias)

resource "azurerm_servicebus_namespace" "secondary" {
  name                         = "sb-demo-secondary"
  location                     = var.secondary_location
  resource_group_name          = azurerm_resource_group.sb_rg.name
  sku                          = "Premium"
  capacity                     = 1
  premium_messaging_partitions = 1
}

resource "azurerm_private_endpoint" "sb_pe_secondary" {
  name                = "pe-sb-demo-secondary"
  location            = azurerm_servicebus_namespace.secondary.location
  resource_group_name = azurerm_resource_group.sb_rg.name
  subnet_id           = azurerm_subnet.subnet_pe.id

  private_service_connection {
    name                           = "psc-sb-secondary"
    private_connection_resource_id = azurerm_servicebus_namespace.secondary.id
    is_manual_connection           = false
    subresource_names              = ["namespace"]
  }
}

resource "azurerm_private_dns_zone_virtual_network_link" "dns_link_secondary" {
  name                  = "vnet-link-secondary"
  resource_group_name   = azurerm_resource_group.sb_rg.name
  private_dns_zone_name = azurerm_private_dns_zone.sb_dns.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  # depends_on so the PE IP is registered before the link
  depends_on = [azurerm_private_endpoint.sb_pe_secondary]
}

# Ensure DR alias waits for both PEs
resource "azurerm_servicebus_namespace_disaster_recovery_config" "geo_alias" {
  name                 = "sb-demo-alias"
  primary_namespace_id = azurerm_servicebus_namespace.primary.id
  partner_namespace_id = azurerm_servicebus_namespace.secondary.id

  depends_on = [
    azurerm_private_endpoint.sb_pe,
    azurerm_private_endpoint.sb_pe_secondary
  ]
}


## Alert rules (dead letter & server errors)
resource "azurerm_monitor_metric_alert" "dead_letter_alert" {
  name                = "sb-deadletter-alert"
  resource_group_name = azurerm_resource_group.sb_rg.name
  scopes              = [azurerm_servicebus_namespace.primary.id]
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.ServiceBus/namespaces"
    metric_name      = "DeadletteredMessages"
    aggregation      = "Average" # ← Total → Average
    operator         = "GreaterThan"
    threshold        = 100
  }
}


## “known-bad” settings (to watch scripts flag them)

# Intentionally create a queue with status Disabled
resource "azurerm_servicebus_queue" "disabled_queue" {
  name         = "legacy-disabled"
  namespace_id = azurerm_servicebus_namespace.primary.id
  status       = "Disabled"
}

# Add an obsolete SAS key older than N days
resource "azurerm_servicebus_namespace_authorization_rule" "stale_key" {
  name         = "stale-manage-rule"
  namespace_id = azurerm_servicebus_namespace.primary.id
  listen       = true
  send         = true
  manage       = true
}
