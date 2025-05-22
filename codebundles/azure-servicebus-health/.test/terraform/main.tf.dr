###############################################################################
# FOUNDATION  ─ RG, primary VNet, subnet, Log Analytics
###############################################################################

resource "azurerm_resource_group" "sb_rg" {
  name     = var.resource_group
  location = var.location # e.g. "Canada Central"
}

resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-sb-demo"
  location            = azurerm_resource_group.sb_rg.location
  resource_group_name = azurerm_resource_group.sb_rg.name
  address_space       = ["10.50.0.0/20"]
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

###############################################################################
# PRIMARY SERVICE BUS  (Canada Central)
###############################################################################

resource "azurerm_servicebus_namespace" "primary" {
  name                          = "sb-demo-primary"
  location                      = azurerm_resource_group.sb_rg.location
  resource_group_name           = azurerm_resource_group.sb_rg.name
  sku                           = "Premium"
  capacity                      = 1
  premium_messaging_partitions  = 1
  minimum_tls_version           = "1.2"
  public_network_access_enabled = false
  identity { type = "SystemAssigned" }
}

###############################################################################
# PRIMARY PRIVATE ENDPOINT  (Canada Central)
###############################################################################

resource "azurerm_private_endpoint" "sb_pe" {
  name                = "pe-sb-demo-primary"
  location            = azurerm_resource_group.sb_rg.location # Canada Central
  resource_group_name = azurerm_resource_group.sb_rg.name
  subnet_id           = azurerm_subnet.subnet_pe.id

  private_service_connection {
    name                           = "psc-sb-primary"
    private_connection_resource_id = azurerm_servicebus_namespace.primary.id
    is_manual_connection           = false
    subresource_names              = ["namespace"]
  }
}

###############################################################################
# PRIVATE DNS ZONE  +  CANADA-CENTRAL LINK
###############################################################################

resource "azurerm_private_dns_zone" "sb_dns" {
  name                = "privatelink.servicebus.windows.net"
  resource_group_name = azurerm_resource_group.sb_rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "dns_link_primary" {
  name                  = "vnet-link"
  resource_group_name   = azurerm_resource_group.sb_rg.name
  private_dns_zone_name = azurerm_private_dns_zone.sb_dns.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

###############################################################################
# SECONDARY SERVICE BUS  (East US)
###############################################################################

resource "azurerm_servicebus_namespace" "secondary" {
  name                         = "sb-demo-secondary"
  location                     = var.secondary_location # e.g. "East US"
  resource_group_name          = azurerm_resource_group.sb_rg.name
  sku                          = "Premium"
  capacity                     = 1
  premium_messaging_partitions = 1
}

###############################################################################
# EAST-US  VNet + subnet  +  PE  +  DNS LINK
###############################################################################

resource "azurerm_virtual_network" "vnet_east" {
  name                = "vnet-sb-demo-east"
  location            = var.secondary_location
  resource_group_name = azurerm_resource_group.sb_rg.name
  address_space       = ["10.60.0.0/20"]
}

resource "azurerm_subnet" "subnet_pe_east" {
  name                 = "snet-sb-pe-east"
  resource_group_name  = azurerm_resource_group.sb_rg.name
  virtual_network_name = azurerm_virtual_network.vnet_east.name
  address_prefixes     = ["10.60.1.0/24"]
}

resource "azurerm_private_endpoint" "sb_pe_secondary" {
  name                = "pe-sb-demo-secondary"
  location            = var.secondary_location # East US
  resource_group_name = azurerm_resource_group.sb_rg.name
  subnet_id           = azurerm_subnet.subnet_pe_east.id

  private_service_connection {
    name                           = "psc-sb-secondary"
    private_connection_resource_id = azurerm_servicebus_namespace.secondary.id
    is_manual_connection           = false
    subresource_names              = ["namespace"]
  }
}

resource "azurerm_private_dns_zone_virtual_network_link" "dns_link_secondary" {
  name                  = "vnet-link-east"
  resource_group_name   = azurerm_resource_group.sb_rg.name
  private_dns_zone_name = azurerm_private_dns_zone.sb_dns.name
  virtual_network_id    = azurerm_virtual_network.vnet_east.id
}

###############################################################################
# GEO-DR ALIAS  (waits for both PEs)
###############################################################################

resource "azurerm_servicebus_namespace_disaster_recovery_config" "geo_alias" {
  name                 = "sb-demo-alias"
  primary_namespace_id = azurerm_servicebus_namespace.primary.id
  partner_namespace_id = azurerm_servicebus_namespace.secondary.id

  # Make sure alias creation waits for both private-endpoints
  depends_on = [
    azurerm_private_endpoint.sb_pe,
    azurerm_private_endpoint.sb_pe_secondary
  ]

  # ───── destroy-time: break & delete alias so namespaces can be removed ─────
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/usr/bin/env", "bash", "-c"]

    command = <<EOT
set -euo pipefail

# self.primary_namespace_id example:
# /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ServiceBus/namespaces/sb-demo-primary
ID="${self.primary_namespace_id}"
RG=$(echo "$ID" | awk -F'/resourceGroups/' '{print $2}' | cut -d'/' -f1)
NS=$(echo "$ID" | awk -F'/namespaces/'     '{print $2}' | cut -d'/' -f1)
ALIAS="${self.name}"

echo "Breaking Service Bus Geo-DR alias $ALIAS (RG=$RG, NS=$NS)…"

# 1. Break the pairing (idempotent)
az servicebus georecovery-alias break-pair \
  --resource-group "$RG" \
  --namespace-name "$NS" \
  --alias "$ALIAS" || true

# 2. Delete the DR object (ignore 404 if it was removed already)
az servicebus georecovery-alias delete \
  --resource-group "$RG" \
  --namespace-name "$NS" \
  --alias "$ALIAS" || true
EOT
  }
}


###############################################################################
# METRICS ENTITIES, ALERT, “KNOWN-BAD” QUEUE & SAS RULE (unchanged)
###############################################################################

resource "azurerm_servicebus_queue" "orders" {
  name                                    = "orders-queue"
  namespace_id                            = azurerm_servicebus_namespace.primary.id
  dead_lettering_on_message_expiration    = true
  auto_delete_on_idle                     = "P14D"
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

resource "azurerm_monitor_diagnostic_setting" "sb_diag" {
  name                       = "diag-to-law"
  target_resource_id         = azurerm_servicebus_namespace.primary.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id

  enabled_log { category = "OperationalLogs" }
  enabled_log { category = "RuntimeAuditLogs" }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

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
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 100
  }
}

resource "azurerm_servicebus_queue" "disabled_queue" {
  name         = "legacy-disabled"
  namespace_id = azurerm_servicebus_namespace.primary.id
  status       = "Disabled"
}

resource "azurerm_servicebus_namespace_authorization_rule" "stale_key" {
  name         = "stale-manage-rule"
  namespace_id = azurerm_servicebus_namespace.primary.id
  listen       = true
  send         = true
  manage       = true
}
