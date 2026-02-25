# Random suffix for unique resource names
resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

# Azure Resource Group for test resources
resource "azurerm_resource_group" "test" {
  name     = "${var.resource_group}-${random_string.suffix.result}"
  location = var.location
  tags     = var.tags
}

# Azure DevOps Projects for organization-wide testing
resource "azuredevops_project" "test_projects" {
  for_each = var.test_projects

  name               = "${each.value.name}-${random_string.suffix.result}"
  description        = each.value.description
  visibility         = "private"
  version_control    = "Git"
  work_item_template = "Agile"

  features = {
    "boards"       = "enabled"
    "repositories" = "enabled"
    "pipelines"    = "enabled"
    "testplans"    = "disabled"
    "artifacts"    = "enabled"
  }
}

# Agent pools for capacity testing
resource "azuredevops_agent_pool" "test_pools" {
  for_each = var.agent_pools

  name           = "${each.value.name}-${random_string.suffix.result}"
  auto_provision = each.value.auto_provision
  auto_update    = each.value.auto_update
}

# Agent pool permissions for testing
resource "azuredevops_agent_queue" "project_queues" {
  for_each = {
    for pair in setproduct(keys(var.test_projects), keys(var.agent_pools)) : 
    "${pair[0]}-${pair[1]}" => {
      project = pair[0]
      pool    = pair[1]
    }
  }

  project_id    = azuredevops_project.test_projects[each.value.project].id
  agent_pool_id = azuredevops_agent_pool.test_pools[each.value.pool].id

  depends_on = [
    azuredevops_project.test_projects,
    azuredevops_agent_pool.test_pools
  ]
}

# Service connections for security testing
resource "azuredevops_serviceendpoint_azurerm" "test_connections" {
  for_each = var.service_connections

  project_id                             = azuredevops_project.test_projects[each.value.project].id
  service_endpoint_name                  = "${each.value.name}-${random_string.suffix.result}"
  description                           = each.value.description
  service_endpoint_authentication_scheme = "ServicePrincipal"
  credentials {
    serviceprincipalid  = var.azure_client_id
    serviceprincipalkey = var.azure_client_secret
  }
  azurerm_spn_tenantid      = var.azure_tenant_id
  azurerm_subscription_id   = var.azure_subscription_id
  azurerm_subscription_name = "Test Subscription"

  depends_on = [azuredevops_project.test_projects]
}

# Build definitions to create load on agent pools
resource "azuredevops_build_definition" "load_generators" {
  for_each = var.load_test_pipelines

  project_id = azuredevops_project.test_projects[each.value.project].id
  name       = "${each.value.name}-${random_string.suffix.result}"

  ci_trigger {
    use_yaml = false
  }

  repository {
    repo_type   = "TfsGit"
    repo_id     = azuredevops_git_repository.test_repos[each.value.project].id
    branch_name = azuredevops_git_repository.test_repos[each.value.project].default_branch
    yml_path    = "azure-pipelines.yml"
  }

  depends_on = [
    azuredevops_project.test_projects,
    azuredevops_git_repository.test_repos
  ]
}

# Repositories for testing
resource "azuredevops_git_repository" "test_repos" {
  for_each = var.test_projects

  project_id = azuredevops_project.test_projects[each.key].id
  name       = "${each.value.name}-repo"

  initialization {
    init_type = "Clean"
  }

  lifecycle {
    ignore_changes = [
      initialization,
    ]
  }

  depends_on = [azuredevops_project.test_projects]
}

# License utilization testing will query existing organization users
# No need to create test users - the health check should analyze real usage patterns

# Security group testing will analyze existing organization groups
# No need to create test groups - security analysis should check real group permissions

# Variable groups for cross-project dependencies
resource "azuredevops_variable_group" "cross_project" {
  for_each = var.test_projects

  project_id   = azuredevops_project.test_projects[each.key].id
  name         = "shared-variables-${random_string.suffix.result}"
  description  = "Shared variables for cross-project testing"
  allow_access = true

  variable {
    name  = "SHARED_RESOURCE"
    value = azurerm_resource_group.test.name
  }

  variable {
    name         = "SECRET_VALUE"
    secret_value = "test-secret-${random_string.suffix.result}"
    is_secret    = true
  }

  depends_on = [azuredevops_project.test_projects]
}

# Load generation scripts
resource "local_file" "agent_load_script" {
  for_each = var.agent_pools

  content = templatefile("${path.module}/scripts/generate-agent-load.sh", {
    pool_name = azuredevops_agent_pool.test_pools[each.key].name
    org_url   = var.azure_devops_org_url
    projects  = [for p in azuredevops_project.test_projects : p.name]
  })
  filename = "${path.module}/generated-files/${each.key}-load-script.sh"

  depends_on = [
    azuredevops_agent_pool.test_pools,
    azuredevops_project.test_projects
  ]
}

# License utilization analysis script (static copy - no template processing needed)
resource "local_file" "license_analysis_script" {
  content  = file("${path.module}/scripts/analyze-licenses.sh")
  filename = "${path.module}/generated-files/license-analysis.sh"
}

# Security policy validation script
resource "local_file" "security_validation_script" {
  content = templatefile("${path.module}/scripts/validate-security.sh", {
    org_url       = var.azure_devops_org_url
    projects      = [for p in azuredevops_project.test_projects : p.name]
    service_conns = [for s in azuredevops_serviceendpoint_azurerm.test_connections : s.service_endpoint_name]
  })
  filename = "${path.module}/generated-files/security-validation.sh"

  depends_on = [
    azuredevops_project.test_projects,
    azuredevops_serviceendpoint_azurerm.test_connections
  ]
}

# Cross-project dependency setup script
resource "local_file" "dependency_setup_script" {
  content = templatefile("${path.module}/scripts/setup-dependencies.sh", {
    org_url      = var.azure_devops_org_url
    projects     = [for p in azuredevops_project.test_projects : p.name]
    var_groups   = [for v in azuredevops_variable_group.cross_project : v.name]
  })
  filename = "${path.module}/generated-files/dependency-setup.sh"

  depends_on = [
    azuredevops_project.test_projects,
    azuredevops_variable_group.cross_project
  ]
}

# Make all scripts executable
resource "null_resource" "make_scripts_executable" {
  triggers = {
    scripts_hash = join(",", [
      for f in local_file.agent_load_script : f.filename
    ])
  }

  provisioner "local-exec" {
    command = "chmod +x ${path.module}/generated-files/*.sh"
  }

  depends_on = [
    local_file.agent_load_script,
    local_file.license_analysis_script,
    local_file.security_validation_script,
    local_file.dependency_setup_script
  ]
}

# Data source for current Azure AD configuration
data "azuread_client_config" "current" {}

# Validation test script
resource "local_file" "validation_test_script" {
  content = templatefile("${path.module}/scripts/run-validation-tests.sh", {
    org_url        = var.azure_devops_org_url
    resource_group = azurerm_resource_group.test.name
    projects       = [for p in azuredevops_project.test_projects : p.name]
    agent_pools    = [for pool in azuredevops_agent_pool.test_pools : pool.name]
  })
  filename = "${path.module}/generated-files/run-validation-tests.sh"

  depends_on = [
    azurerm_resource_group.test,
    azuredevops_project.test_projects,
    azuredevops_agent_pool.test_pools
  ]
} 