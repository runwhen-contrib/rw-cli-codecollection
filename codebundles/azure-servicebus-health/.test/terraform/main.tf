###############################################################################
# FOUNDATION  – RG, Log-Analytics
###############################################################################

resource "azurerm_resource_group" "sb_rg" {
  name     = var.resource_group # e.g. "azure-servicebus-health"
  location = var.location       # e.g. "Canada Central"
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-sb-health-demo"
  location            = azurerm_resource_group.sb_rg.location
  resource_group_name = azurerm_resource_group.sb_rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

###############################################################################
# SERVICE BUS  – single Standard namespace (no private link)
###############################################################################

resource "azurerm_servicebus_namespace" "primary" {
  name                         = "sb-demo-primary"
  location                     = azurerm_resource_group.sb_rg.location
  resource_group_name          = azurerm_resource_group.sb_rg.name
  sku                          = "Standard" # keep Premium to test features
  capacity                     = 1
  premium_messaging_partitions = 1
  minimum_tls_version          = "1.2"

  # Allow public access so no PE / VNet is required
  public_network_access_enabled = true

  identity { type = "SystemAssigned" }
}

###############################################################################
# ENTITIES  – queue, topic, subscription
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

###############################################################################
# DIAGNOSTIC SETTINGS  – logs + metrics to Log Analytics
###############################################################################

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

###############################################################################
# METRIC ALERT  – dead-letter depth
###############################################################################

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

###############################################################################
# “KNOWN-BAD” TEST OBJECTS  – disabled queue and stale SAS rule
###############################################################################

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
