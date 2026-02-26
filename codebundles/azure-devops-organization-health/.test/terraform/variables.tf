variable "azure_devops_org" {
  description = "Azure DevOps organization name"
  type        = string
}

variable "azure_devops_org_url" {
  description = "Azure DevOps organization URL"
  type        = string
}

variable "azure_devops_pat" {
  description = "Azure DevOps Personal Access Token"
  type        = string
  sensitive   = true
}

variable "resource_group" {
  description = "Azure resource group name for test resources"
  type        = string
  default     = "rg-devops-org-health-test"
}

variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "East US"
}

variable "azure_subscription_id" {
  description = "Azure subscription ID"
  type        = string
  sensitive   = true
}

variable "azure_tenant_id" {
  description = "Azure tenant ID"
  type        = string
  sensitive   = true
}

variable "azure_client_id" {
  description = "Azure client ID for service principal"
  type        = string
  sensitive   = true
}

variable "azure_client_secret" {
  description = "Azure client secret for service principal"
  type        = string
  sensitive   = true
}



variable "agent_utilization_threshold" {
  description = "Agent pool utilization threshold percentage"
  type        = number
  default     = 80
}

variable "license_utilization_threshold" {
  description = "License utilization threshold percentage"
  type        = number
  default     = 90
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default = {
    Environment = "test"
    Purpose     = "organization-health-testing"
  }
}

variable "test_projects" {
  description = "Test projects for organization health testing"
  type = map(object({
    name        = string
    description = string
  }))
  default = {
    high_capacity = {
      name        = "high-capacity-project"
      description = "Project for testing high agent capacity usage"
    }
    license_test = {
      name        = "license-test-project"
      description = "Project for testing license utilization scenarios"
    }
    security_test = {
      name        = "security-test-project"
      description = "Project for testing security policy violations"
    }
    cross_deps = {
      name        = "cross-dependencies-project"
      description = "Project for testing cross-project dependencies"
    }
    service_health = {
      name        = "service-health-project"
      description = "Project for testing service connectivity issues"
    }
  }
}

variable "agent_pools" {
  description = "Agent pools for capacity testing"
  type = map(object({
    name           = string
    auto_provision = bool
    auto_update    = bool
  }))
  default = {
    overutilized = {
      name           = "overutilized-pool"
      auto_provision = false
      auto_update    = true
    }
    undersized = {
      name           = "undersized-pool"
      auto_provision = false
      auto_update    = true
    }
    offline_agents = {
      name           = "offline-agents-pool"
      auto_provision = false
      auto_update    = false
    }
    misconfigured = {
      name           = "misconfigured-pool"
      auto_provision = true
      auto_update    = false
    }
  }
}

variable "service_connections" {
  description = "Service connections for security testing"
  type = map(object({
    name        = string
    description = string
    project     = string
  }))
  default = {
    weak_security = {
      name        = "weak-security-connection"
      description = "Service connection with weak security for testing"
      project     = "security_test"
    }
    over_permissions = {
      name        = "over-permissions-connection"
      description = "Service connection with excessive permissions"
      project     = "security_test"
    }
    unsecured = {
      name        = "unsecured-connection"
      description = "Service connection without proper security"
      project     = "service_health"
    }
  }
}





variable "load_test_pipelines" {
  description = "Build pipelines for generating agent load"
  type = map(object({
    name    = string
    project = string
  }))
  default = {
    capacity_load = {
      name    = "capacity-load-pipeline"
      project = "high_capacity"
    }
    stress_test = {
      name    = "stress-test-pipeline"
      project = "high_capacity"
    }
    dependency_test = {
      name    = "dependency-test-pipeline"
      project = "cross_deps"
    }
  }
} 