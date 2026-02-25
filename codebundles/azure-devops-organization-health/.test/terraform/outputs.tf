output "resource_group_name" {
  description = "Name of the created resource group"
  value       = azurerm_resource_group.test.name
}

output "resource_group_location" {
  description = "Location of the created resource group"
  value       = azurerm_resource_group.test.location
}

output "devops_org" {
  description = "Azure DevOps organization name"
  value       = var.azure_devops_org
}

output "org_url" {
  description = "Azure DevOps organization URL"
  value       = var.azure_devops_org_url
}

output "test_projects" {
  description = "Created test projects"
  value = {
    for k, v in azuredevops_project.test_projects : k => {
      id   = v.id
      name = v.name
      url  = "${var.azure_devops_org_url}/${v.name}"
    }
  }
}

output "agent_pools" {
  description = "Created agent pools"
  value = {
    for k, v in azuredevops_agent_pool.test_pools : k => {
      id   = v.id
      name = v.name
    }
  }
}

output "service_connections" {
  description = "Created service connections"
  value = {
    for k, v in azuredevops_serviceendpoint_azurerm.test_connections : k => {
      id   = v.id
      name = v.service_endpoint_name
    }
  }
  sensitive = true
}



output "generated_scripts" {
  description = "Paths to generated test scripts"
  value = {
    agent_load_scripts = {
      for k, v in local_file.agent_load_script : k => v.filename
    }
    license_analysis_script    = local_file.license_analysis_script.filename
    security_validation_script = local_file.security_validation_script.filename
    dependency_setup_script    = local_file.dependency_setup_script.filename
    validation_test_script     = local_file.validation_test_script.filename
  }
}

output "random_suffix" {
  description = "Random suffix used for resource names"
  value       = random_string.suffix.result
}

output "agent_utilization_threshold" {
  description = "Configured agent utilization threshold"
  value       = var.agent_utilization_threshold
}

output "license_utilization_threshold" {
  description = "Configured license utilization threshold"
  value       = var.license_utilization_threshold
}

output "test_environment_summary" {
  description = "Summary of the test environment"
  value = {
    projects_created            = length(azuredevops_project.test_projects)
    agent_pools_created         = length(azuredevops_agent_pool.test_pools)
    service_connections_created = length(azuredevops_serviceendpoint_azurerm.test_connections)
    random_suffix              = random_string.suffix.result
  }
} 