# Current sub (assumed from CLI login)
data "azurerm_subscription" "current" {}

# Get tenant and user details of the current CLI session
data "azurerm_client_config" "current" {}

# Resource Group
resource "azurerm_resource_group" "test" {
  name     = var.resource_group
  location = var.location
  tags = var.tags

}

# Create a new managed identity
resource "azurerm_user_assigned_identity" "aks_identity" {
  name                = "${var.cluster_name}-identity"
  location            = var.location
  resource_group_name = var.resource_group
  depends_on = [azurerm_resource_group.test]
}

# Assign "Reader" role to the service account for the resource group
resource "azurerm_role_assignment" "reader" {
  scope                = azurerm_resource_group.test.id
  role_definition_name = "Reader"
  principal_id         = var.sp_principal_id
}

# Assign Owner role to the managed identity for the resource group
resource "azurerm_role_assignment" "aks_identity_owner_rg" {
  principal_id         = azurerm_user_assigned_identity.aks_identity.principal_id
  role_definition_name = "Owner"
  scope                = azurerm_resource_group.test.id
}

# VNET and Subnet for Azure CNI
resource "azurerm_virtual_network" "aks_vnet" {
  name                = "${var.cluster_name}-vnet"
  location            = var.location
  resource_group_name = azurerm_resource_group.test.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "aks_subnet" {
  name                 = "${var.cluster_name}-subnet"
  resource_group_name  = azurerm_resource_group.test.name
  virtual_network_name = azurerm_virtual_network.aks_vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Network Security Group for subnet
resource "azurerm_network_security_group" "aks_nsg" {
  name                = "${var.cluster_name}-nsg"
  location            = var.location
  resource_group_name = azurerm_resource_group.test.name
}

resource "azurerm_subnet_network_security_group_association" "aks_subnet_nsg" {
  subnet_id                 = azurerm_subnet.aks_subnet.id
  network_security_group_id = azurerm_network_security_group.aks_nsg.id
}

# Route Table for subnet
resource "azurerm_route_table" "aks_route_table" {
  name                = "${var.cluster_name}-route-table"
  location            = var.location
  resource_group_name = azurerm_resource_group.test.name
}

resource "azurerm_subnet_route_table_association" "route_table_association" {
  subnet_id      = azurerm_subnet.aks_subnet.id
  route_table_id = azurerm_route_table.aks_route_table.id
}

# AKS Cluster
resource "azurerm_kubernetes_cluster" "aks_cluster" {
  depends_on = [azurerm_user_assigned_identity.aks_identity]
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group
  dns_prefix          = "aks-${var.cluster_name}"

  default_node_pool {
    name            = "default"
    node_count      = 1
    vm_size         = "Standard_DC2s_v2"
    vnet_subnet_id  = azurerm_subnet.aks_subnet.id  # Updated for Azure CNI with VNET and Subnet
  }

  identity {
    type          = "UserAssigned"
    identity_ids  = [azurerm_user_assigned_identity.aks_identity.id]
  }

  kubelet_identity {
    client_id                 = azurerm_user_assigned_identity.aks_identity.client_id
    object_id                 = azurerm_user_assigned_identity.aks_identity.principal_id
    user_assigned_identity_id = azurerm_user_assigned_identity.aks_identity.id
  }

  # Network Profile to switch from Kubenet to Azure CNI
  network_profile {
    network_plugin    = "azure"   # Switch from "kubenet" to "azure" for Azure CNI
    service_cidr      = "10.0.2.0/24"
    dns_service_ip    = "10.0.2.10"
  }

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id = var.tenant_id
  }

  lifecycle {
    ignore_changes = [
      default_node_pool[0].upgrade_settings,
      kubelet_identity[0].user_assigned_identity_id
    ]
  }
  tags = var.tags
}

resource "tls_private_key" "ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

output "ssh_key_pem" {
  value     = tls_private_key.ssh_key.private_key_pem
  sensitive = true
}

output "ssh_key_public" {
  value = tls_private_key.ssh_key.public_key_openssh
}

output "cluster_fqdn" {
    value = azurerm_kubernetes_cluster.aks_cluster.fqdn
}

# Null resource to handle role assignments and credential retrieval
resource "null_resource" "aks_role_assignments" {
  provisioner "local-exec" {
    command = <<EOT
      # Retrieve agent pool client ID
      AGENT_POOL_ID=$(az aks show --name ${var.cluster_name} --resource-group ${var.resource_group} --query "identityProfile.kubeletidentity.clientId" --output tsv)

      # Assign Azure Kubernetes Service RBAC Cluster Admin role to agent pool
      az role assignment create --assignee $AGENT_POOL_ID --role "Azure Kubernetes Service RBAC Cluster Admin" --scope $(az aks show --resource-group ${var.resource_group} --name ${var.cluster_name} --query id --output tsv)

      # Assign Owner role to agent pool at the subscription level
      az role assignment create --assignee $AGENT_POOL_ID --role "Owner" --scope /subscriptions/${data.azurerm_subscription.current.subscription_id}

      # Retrieve AKS credentials
      az aks get-credentials --resource-group ${var.resource_group} --name ${var.cluster_name} --overwrite-existing
    EOT
    interpreter = ["/bin/bash", "-c"]
  }

  depends_on = [azurerm_kubernetes_cluster.aks_cluster]
}

# Assign the current logged-in user as a Kubernetes RBAC Cluster Admin
resource "azurerm_role_assignment" "current_user_k8s_admin" {
  principal_id         = data.azurerm_client_config.current.object_id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  scope                = azurerm_kubernetes_cluster.aks_cluster.id
}

# Assign the service principal as a Kubernetes RBAC Cluster Admin
resource "azurerm_role_assignment" "sp_k8s_admin" {
  principal_id         = var.sp_principal_id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  scope                = azurerm_kubernetes_cluster.aks_cluster.id
}
