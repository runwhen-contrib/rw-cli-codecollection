# Current sub (assumed from cli login)
data "azurerm_subscription" "current" {
}

# Get tenant and user details of the current CLI session
data "azurerm_client_config" "current" {}


# Resource Group
resource "azurerm_resource_group" "test" {
  name     = var.resource_group
  location = var.location
}

# Create a new managed identity
resource "azurerm_user_assigned_identity" "aks_identity" {
  name                = "${var.cluster_name}-identity"
  location            = var.location
  resource_group_name = var.resource_group
  depends_on = [azurerm_resource_group.test]
}

# Assign Owner role to the managed identity for the resource group
resource "azurerm_role_assignment" "aks_identity_owner_rg" {
  principal_id   = azurerm_user_assigned_identity.aks_identity.principal_id
  role_definition_name = "Owner"
  scope          = azurerm_resource_group.test.id
}

# AKS Cluster
resource "azurerm_kubernetes_cluster" "aks_cluster" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group
  dns_prefix          = "aks-${var.cluster_name}"

  default_node_pool {
    name       = "default"
    node_count = 1
    vm_size    = "Standard_DC2s_v2"  # Min size for a default node pool
  }

  identity {
    type = "UserAssigned"
     identity_ids = [azurerm_user_assigned_identity.aks_identity.id]

  }

  kubelet_identity {
    client_id                 = azurerm_user_assigned_identity.aks_identity.client_id
    object_id                 = azurerm_user_assigned_identity.aks_identity.principal_id
    user_assigned_identity_id = azurerm_user_assigned_identity.aks_identity.id
  }

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id = var.tenant_id
  }

  lifecycle {
    ignore_changes = [kubelet_identity[0].user_assigned_identity_id]  # Helps avoid re-provisioning issues with identity
  }
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