# Retrieve subscription and tenant details
data "azurerm_subscription" "current" {}
data "azurerm_client_config" "current" {}


# Resource Group
resource "azurerm_resource_group" "test" {
  name     = var.resource_group
  location = var.location
  tags     = var.tags
}

# Virtual Network and Subnet
resource "azurerm_virtual_network" "vnet" {
  name                = "appgw-vnet"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  address_space       = ["10.0.0.0/16"]
  tags                = var.tags
}

resource "azurerm_subnet" "appgw_subnet" {
  name                 = "appgw-subnet"
  resource_group_name  = azurerm_resource_group.test.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# App Service Plans
resource "azurerm_service_plan" "app1" {
  name                = "${var.resource_group}-app1-service-plan"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  os_type             = "Linux"
  sku_name            = "B1"
}

resource "azurerm_service_plan" "app2" {
  name                = "${var.resource_group}-app2-service-plan"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  os_type             = "Linux"
  sku_name            = "B1"
}

# App Services
resource "azurerm_linux_web_app" "app1" {
  name                = "${var.resource_group}-app1-web"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  service_plan_id     = azurerm_service_plan.app1.id

  site_config {
    always_on = true
  }

  tags = var.tags
}

resource "azurerm_linux_web_app" "app2" {
  name                = "${var.resource_group}-app2-web"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  service_plan_id     = azurerm_service_plan.app2.id

  site_config {
    always_on                         = true
    health_check_path                 = "/"
    health_check_eviction_time_in_min = 2
  }

  tags = var.tags
}

# Public IPs for Application Gateways
resource "azurerm_public_ip" "appgw1" {
  name                = "appgw1-pip"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  allocation_method   = "Dynamic"
}

resource "azurerm_public_ip" "appgw2" {
  name                = "appgw2-pip"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  allocation_method   = "Dynamic"
}

# Application Gateways
resource "azurerm_application_gateway" "appgw1" {
  name                = "appgw1"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 1
  }

  gateway_ip_configuration {
    name      = "appgw1-ipconfig"
    subnet_id = azurerm_subnet.appgw_subnet.id
  }

  frontend_port {
    name = "appgw1-port"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "appgw1-frontend"
    public_ip_address_id = azurerm_public_ip.appgw1.id
  }

  backend_address_pool {
    name = "app1-pool"
  }

  backend_http_settings {
    name                  = "default-http-settings"
    cookie_based_affinity = "Disabled"
    path                  = "/"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 20
  }

  http_listener {
    name                           = "appgw1-listener"
    frontend_ip_configuration_name = "appgw1-frontend"
    frontend_port_name             = "appgw1-port"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "app1-rule"
    rule_type                  = "Basic"
    http_listener_name         = "appgw1-listener"
    backend_address_pool_name  = "app1-pool"
    backend_http_settings_name = "default-http-settings"
  }

  tags = var.tags
}

resource "azurerm_application_gateway" "appgw2" {
  name                = "appgw2"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 1
  }

  gateway_ip_configuration {
    name      = "appgw2-ipconfig"
    subnet_id = azurerm_subnet.appgw_subnet.id
  }

  frontend_port {
    name = "appgw2-port"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "appgw2-frontend"
    public_ip_address_id = azurerm_public_ip.appgw2.id
  }

  backend_address_pool {
    name = "app2-pool"
  }

  backend_http_settings {
    name                  = "default-http-settings"
    cookie_based_affinity = "Disabled"
    path                  = "/"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 20
  }

  http_listener {
    name                           = "appgw2-listener"
    frontend_ip_configuration_name = "appgw2-frontend"
    frontend_port_name             = "appgw2-port"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "app2-rule"
    rule_type                  = "Basic"
    http_listener_name         = "appgw2-listener"
    backend_address_pool_name  = "app2-pool"
    backend_http_settings_name = "default-http-settings"
  }

  tags = var.tags
}

# Outputs
output "app1_url" {
  value = azurerm_linux_web_app.app1.default_hostname
}

output "app2_url" {
  value = azurerm_linux_web_app.app2.default_hostname
}

output "appgw1_public_ip" {
  value = azurerm_public_ip.appgw1.ip_address
}

output "appgw2_public_ip" {
  value = azurerm_public_ip.appgw2.ip_address
}
