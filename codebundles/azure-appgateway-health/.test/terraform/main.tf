###############################################################################
# Data Sources
###############################################################################
data "azurerm_subscription" "current" {}
data "azurerm_client_config" "current" {}

###############################################################################
# Resource Group
###############################################################################
resource "azurerm_resource_group" "test" {
  name     = var.resource_group
  location = var.location
  tags     = var.tags
}

###############################################################################
# Role Assignments
###############################################################################
resource "azurerm_role_assignment" "reader" {
  scope                = azurerm_resource_group.test.id
  role_definition_name = "Reader"
  principal_id         = var.sp_principal_id
}

resource "azurerm_role_assignment" "website-contributor" {
  scope                = azurerm_resource_group.test.id
  role_definition_name = "Network Contributor"
  principal_id         = var.sp_principal_id
}

###############################################################################
# Virtual Network & Subnet
###############################################################################
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

###############################################################################
# App Service Plans
###############################################################################
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

###############################################################################
# App Services
###############################################################################
resource "azurerm_linux_web_app" "app1" {
  name                = "${var.resource_group}-app1-web"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  service_plan_id     = azurerm_service_plan.app1.id

  app_settings = {
    "GAME" = "oregon"
  }

  site_config {
    always_on                         = true
    health_check_path                 = "/"
    health_check_eviction_time_in_min = 2
    application_stack {
      docker_image_name   = "stewartshea/js-dos-container:latest"
      docker_registry_url = "https://ghcr.io"
    }
  }
  tags = var.tags
}

resource "azurerm_linux_web_app" "app2" {
  name                = "${var.resource_group}-app2-web"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  service_plan_id     = azurerm_service_plan.app2.id

  app_settings = {
    "GAME" = "scorched_earth"
  }

  site_config {
    always_on                         = true
    health_check_path                 = "/"
    health_check_eviction_time_in_min = 2
    application_stack {
      docker_image_name   = "stewartshea/js-dos-container:broken"
      docker_registry_url = "https://ghcr.io"
    }
  }
  tags = var.tags
}

###############################################################################
# Public IPs (for both App Gateways)
###############################################################################
resource "azurerm_public_ip" "appgw1" {
  name                = "appgw1-pip"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  allocation_method   = "Static"
}

resource "azurerm_public_ip" "appgw2" {
  name                = "appgw2-pip"
  location            = azurerm_resource_group.test.location
  resource_group_name = azurerm_resource_group.test.name
  allocation_method   = "Static"
}

###############################################################################
# Self-Signed Certs & PKCS#12 Generation (14-day expiry)
###############################################################################
# 1) RSA Keys
resource "tls_private_key" "appgw1_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_private_key" "appgw2_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

# 2) Self-Signed Certificates (PEM) - 14 days
resource "tls_self_signed_cert" "appgw1_cert" {
  private_key_pem = tls_private_key.appgw1_key.private_key_pem

  subject {
    common_name  = "appgw1.local"
    organization = "TestOrg"
  }

  validity_period_hours = 14 * 24  # 14 days
  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth"
  ]
}

resource "tls_self_signed_cert" "appgw2_cert" {
  private_key_pem = tls_private_key.appgw2_key.private_key_pem

  subject {
    common_name  = "appgw2.local"
    organization = "TestOrg"
  }

  validity_period_hours = 14 * 24
  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth"
  ]
}

###############################################################################
# Convert PEM + Key -> PFX (base64)
###############################################################################
data "external" "appgw1_pfx" {
  program = [
    "bash",
    "-c",
    // ONE SINGLE LINE (no backslash, no heredoc, no multiple lines):
    "set -e; input=$(cat); cert_pem=$(echo \"$input\" | jq -r '.cert_pem'); key_pem=$(echo \"$input\" | jq -r '.key_pem'); pass=$(echo \"$input\" | jq -r '.pass'); echo \"$cert_pem\" > ./tmp_cert1.pem; echo \"$key_pem\" > ./tmp_key1.pem; openssl pkcs12 -export -in ./tmp_cert1.pem -inkey ./tmp_key1.pem -out ./tmp_cert1.pfx -name selfsigned-appgw1 -passout pass:\"$pass\" >/dev/null 2>&1; pfx_b64=$(base64 ./tmp_cert1.pfx | tr -d '\\n'); printf '{\"pfx_base64\":\"%s\"}' \"$pfx_b64\";"
  ]

  query = {
    cert_pem = tls_self_signed_cert.appgw1_cert.cert_pem
    key_pem  = tls_private_key.appgw1_key.private_key_pem
    pass     = var.ssl_cert_password
  }
}

data "external" "appgw2_pfx" {
  program = [
    "bash",
    "-c",
    // ONE SINGLE LINE (no backslash, no heredoc, no multiple lines):
    "set -e; input=$(cat); cert_pem=$(echo \"$input\" | jq -r '.cert_pem'); key_pem=$(echo \"$input\" | jq -r '.key_pem'); pass=$(echo \"$input\" | jq -r '.pass'); echo \"$cert_pem\" > ./tmp_cert2.pem; echo \"$key_pem\" > ./tmp_key2.pem; openssl pkcs12 -export -in ./tmp_cert2.pem -inkey ./tmp_key2.pem -out ./tmp_cert2.pfx -name selfsigned-appgw2 -passout pass:\"$pass\" >/dev/null 2>&1; pfx_b64=$(base64 ./tmp_cert2.pfx | tr -d '\\n'); printf '{\"pfx_base64\":\"%s\"}' \"$pfx_b64\";"
  ]

  query = {
    cert_pem = tls_self_signed_cert.appgw2_cert.cert_pem
    key_pem  = tls_private_key.appgw2_key.private_key_pem
    pass     = var.ssl_cert_password
  }
}



###############################################################################
# Application Gateway 1
###############################################################################
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

  # Existing front-end port for HTTP (80)
  frontend_port {
    name = "appgw1-port"
    port = 80
  }

  # NEW front-end port for HTTPS (443)
  frontend_port {
    name = "appgw1-port-https"
    port = 443
  }

  frontend_ip_configuration {
    name                 = "appgw1-frontend"
    public_ip_address_id = azurerm_public_ip.appgw1.id
  }

  backend_address_pool {
    name  = "app1-pool"
    fqdns = [azurerm_linux_web_app.app1.default_hostname]
  }

  backend_http_settings {
    name                                = "http-settings"
    cookie_based_affinity               = "Disabled"
    port                                = 80
    protocol                            = "Http"
    request_timeout                     = 20
    pick_host_name_from_backend_address = true
  }

  # Existing HTTP listener
  http_listener {
    name                           = "http-listener"
    frontend_ip_configuration_name = "appgw1-frontend"
    frontend_port_name             = "appgw1-port"
    protocol                       = "Http"
  }

  # NEW: HTTPS listener
  http_listener {
    name                           = "https-listener"
    frontend_ip_configuration_name = "appgw1-frontend"
    frontend_port_name             = "appgw1-port-https"
    protocol                       = "Https"
    ssl_certificate_name           = "appgw1-selfsigned"
  }

  # Existing HTTP routing rule
  request_routing_rule {
    name                       = "app1-routing-rule"
    rule_type                  = "Basic"
    http_listener_name         = "http-listener"
    backend_address_pool_name  = "app1-pool"
    backend_http_settings_name = "http-settings"
    priority                   = 200
  }

  # NEW HTTPS routing rule
  request_routing_rule {
    name                       = "app1-routing-rule-https"
    rule_type                  = "Basic"
    http_listener_name         = "https-listener"
    backend_address_pool_name  = "app1-pool"
    backend_http_settings_name = "http-settings"
    priority                   = 201
  }

  # Attach self-signed cert (14-day expiry)
  ssl_certificate {
    name     = "appgw1-selfsigned"
    data     = data.external.appgw1_pfx.result.pfx_base64
    password = var.ssl_cert_password
  }

  tags = var.tags
}

###############################################################################
# Application Gateway 2
###############################################################################
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

  # Existing front-end port for HTTP (80)
  frontend_port {
    name = "appgw2-port"
    port = 80
  }

  # NEW: HTTPS port (443)
  frontend_port {
    name = "appgw2-port-https"
    port = 443
  }

  frontend_ip_configuration {
    name                 = "appgw2-frontend"
    public_ip_address_id = azurerm_public_ip.appgw2.id
  }

  backend_address_pool {
    name  = "app2-pool"
    fqdns = [azurerm_linux_web_app.app2.default_hostname]
  }

  backend_http_settings {
    name                                = "http-settings"
    cookie_based_affinity               = "Disabled"
    port                                = 80
    protocol                            = "Http"
    request_timeout                     = 20
    pick_host_name_from_backend_address = true
  }

  # Existing HTTP listener
  http_listener {
    name                           = "http-listener"
    frontend_ip_configuration_name = "appgw2-frontend"
    frontend_port_name             = "appgw2-port"
    protocol                       = "Http"
  }

  # NEW: HTTPS listener
  http_listener {
    name                           = "https-listener"
    frontend_ip_configuration_name = "appgw2-frontend"
    frontend_port_name             = "appgw2-port-https"
    protocol                       = "Https"
    ssl_certificate_name           = "appgw2-selfsigned"
  }

  # Existing HTTP routing rule
  request_routing_rule {
    name                       = "app2-routing-rule"
    rule_type                  = "Basic"
    http_listener_name         = "http-listener"
    backend_address_pool_name  = "app2-pool"
    backend_http_settings_name = "http-settings"
    priority                   = 200
  }

  # NEW: HTTPS routing rule
  request_routing_rule {
    name                       = "app2-routing-rule-https"
    rule_type                  = "Basic"
    http_listener_name         = "https-listener"
    backend_address_pool_name  = "app2-pool"
    backend_http_settings_name = "http-settings"
    priority                   = 201
  }

  # Attach self-signed cert (14-day expiry)
  ssl_certificate {
    name     = "appgw2-selfsigned"
    data     = data.external.appgw2_pfx.result.pfx_base64
    password = var.ssl_cert_password
  }

  tags = var.tags
}

###############################################################################
# Outputs
###############################################################################
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