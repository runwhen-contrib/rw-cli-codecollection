resource "azurerm_resource_group" "rg" {
  name     = var.resource_group
  location = var.location
  tags     = var.tags
}

data "azurerm_client_config" "current" {}

# Azure DevOps Organization and Project setup
resource "azuredevops_project" "test_project" {
  name               = "DevOps-Triage-Test"
  visibility         = "private"
  version_control    = "Git"
  work_item_template = "Agile"
  description        = "Project for testing Azure DevOps triage scripts"
}

# Create a Git repository in the project with proper initialization
resource "azuredevops_git_repository" "test_repo" {
  project_id = azuredevops_project.test_project.id
  name       = "test-pipeline-repo"
  initialization {
    init_type = "Clean" # This creates an initial commit and main branch
  }
}

# Create a variable group for pipeline variables
resource "azuredevops_variable_group" "test_vars" {
  project_id   = azuredevops_project.test_project.id
  name         = "Test Pipeline Variables"
  description  = "Variables for test pipelines"
  allow_access = true

  variable {
    name  = "TEST_VAR"
    value = "test-value"
  }

  variable {
    name  = "RESOURCE_GROUP"
    value = azurerm_resource_group.rg.name
  }

  variable {
    name  = "AZURE_SUBSCRIPTION_ID"
    value = data.azurerm_client_config.current.subscription_id
  }
}

# Create a self-hosted agent pool
resource "azuredevops_agent_pool" "test_pool" {
  name           = "Test-Agent-Pool"
  auto_provision = false
  auto_update    = true
}

# Create an agent queue for the project
resource "azuredevops_agent_queue" "test_queue" {
  project_id    = azuredevops_project.test_project.id
  agent_pool_id = azuredevops_agent_pool.test_pool.id
}

# Authorize the queue for use by all pipelines
resource "azuredevops_pipeline_authorization" "test_auth" {
  project_id  = azuredevops_project.test_project.id
  resource_id = azuredevops_agent_queue.test_queue.id
  type        = "queue"
}

# Output the agent pool information for manual agent setup
output "agent_pool_setup_instructions" {
  value = <<-EOT
    To set up a self-hosted agent:
    
    1. Download the agent from: https://dev.azure.com/${var.azure_devops_org}/_settings/agentpools?poolId=${azuredevops_agent_pool.test_pool.id}&_a=agents
    
    2. Or follow these steps:
       a. Create a folder on your machine (e.g., mkdir ~/azagent && cd ~/azagent)
       b. Download the agent: curl -O https://vstsagentpackage.azureedge.net/agent/2.214.1/vsts-agent-linux-x64-2.214.1.tar.gz
       c. Extract: tar zxvf vsts-agent-linux-x64-2.214.1.tar.gz
       d. Configure: ./config.sh
          - Server URL: https://dev.azure.com/${var.azure_devops_org}
          - PAT: (your PAT) #generate PAT from the your azure devops org
          - Agent pool: ${azuredevops_agent_pool.test_pool.name}
       e. Run as a service: ./svc.sh install && ./svc.sh start
  EOT
}

# Create a service connection to Azure
resource "azuredevops_serviceendpoint_azurerm" "test_endpoint" {
  project_id                = azuredevops_project.test_project.id
  service_endpoint_name     = "Test-Azure-Connection"
  description               = "Managed by Terraform"
  azurerm_spn_tenantid      = data.azurerm_client_config.current.tenant_id
  azurerm_subscription_id   = data.azurerm_client_config.current.subscription_id
  azurerm_subscription_name = "Test Subscription"
  credentials {
    serviceprincipalid  = var.client_id
    serviceprincipalkey = var.client_secret
  }
}

# Create YAML files for pipelines
resource "local_file" "success_pipeline_yaml" {
  content  = <<-EOT
    trigger:
    - master

    pool:
      name: ${azuredevops_agent_pool.test_pool.name}  # Use self-hosted agent pool

    steps:
    - script: |
        echo "Running successful pipeline"
        echo "This pipeline will succeed"
        echo "Using resource group: $(RESOURCE_GROUP)"
        echo "Agent name: $(Agent.Name)"
        echo "Agent machine name: $(Agent.MachineName)"
      displayName: 'Run successful script'
  EOT
  filename = "${path.module}/success-pipeline.yml"
}

resource "local_file" "failing_pipeline_yaml" {
  content  = <<-EOT
    trigger:
    - master

    pool:
      name: ${azuredevops_agent_pool.test_pool.name}  # Use self-hosted agent pool

    steps:
    - script: |
        echo "Running failing pipeline"
        echo "This pipeline will fail"
        echo "Using resource group: $(RESOURCE_GROUP)"
        echo "Agent name: $(Agent.Name)"
        echo "Agent machine name: $(Agent.MachineName)"
        exit 1
      displayName: 'Run failing script'
  EOT
  filename = "${path.module}/failing-pipeline.yml"
}

resource "local_file" "long_running_pipeline_yaml" {
  content  = <<-EOT
    trigger:
    - master

    pool:
      name: ${azuredevops_agent_pool.test_pool.name}  # Use self-hosted agent pool

    steps:
    - script: |
        echo "Starting long-running pipeline"
        echo "This pipeline will sleep for 5 minutes"  # Reduced time for testing
        echo "Using resource group: $(RESOURCE_GROUP)"
        echo "Agent name: $(Agent.Name)"
        echo "Agent machine name: $(Agent.MachineName)"
        sleep 300
        echo "Long-running pipeline completed"
      displayName: 'Run long script'
  EOT
  filename = "${path.module}/long-running-pipeline.yml"
}

# Upload YAML files to the repository
resource "azuredevops_git_repository_file" "success_pipeline_file" {
  repository_id       = azuredevops_git_repository.test_repo.id
  file                = "success-pipeline.yml"
  content             = local_file.success_pipeline_yaml.content
  branch              = "refs/heads/master" # Use full ref format
  commit_message      = "Add success pipeline YAML"
  overwrite_on_create = true

  depends_on = [azuredevops_git_repository.test_repo]
}

resource "azuredevops_git_repository_file" "failing_pipeline_file" {
  repository_id       = azuredevops_git_repository.test_repo.id
  file                = "failing-pipeline.yml"
  content             = local_file.failing_pipeline_yaml.content
  branch              = "refs/heads/master" # Use full ref format
  commit_message      = "Add failing pipeline YAML"
  overwrite_on_create = true

  depends_on = [azuredevops_git_repository.test_repo]
}

resource "azuredevops_git_repository_file" "long_running_pipeline_file" {
  repository_id       = azuredevops_git_repository.test_repo.id
  file                = "long-running-pipeline.yml"
  content             = local_file.long_running_pipeline_yaml.content
  branch              = "refs/heads/master" # Use full ref format
  commit_message      = "Add long-running pipeline YAML"
  overwrite_on_create = true

  depends_on = [azuredevops_git_repository.test_repo]
}

# Create the pipelines
resource "azuredevops_build_definition" "success_pipeline" {
  project_id = azuredevops_project.test_project.id
  name       = "Success-Pipeline"
  path       = "\\Test"

  ci_trigger {
    use_yaml = true
  }

  repository {
    repo_type   = "TfsGit"
    repo_id     = azuredevops_git_repository.test_repo.id
    branch_name = "refs/heads/master"
    yml_path    = "success-pipeline.yml"
  }

  variable_groups = [
    azuredevops_variable_group.test_vars.id
  ]

  depends_on = [
    azuredevops_git_repository_file.success_pipeline_file,
    azuredevops_pipeline_authorization.test_auth
  ]
}

resource "azuredevops_build_definition" "failing_pipeline" {
  project_id = azuredevops_project.test_project.id
  name       = "Failing-Pipeline"
  path       = "\\Test"

  ci_trigger {
    use_yaml = true
  }

  repository {
    repo_type   = "TfsGit"
    repo_id     = azuredevops_git_repository.test_repo.id
    branch_name = "refs/heads/master"
    yml_path    = "failing-pipeline.yml"
  }

  variable_groups = [
    azuredevops_variable_group.test_vars.id
  ]

  depends_on = [
    azuredevops_git_repository_file.failing_pipeline_file,
    azuredevops_pipeline_authorization.test_auth
  ]
}

resource "azuredevops_build_definition" "long_running_pipeline" {
  project_id = azuredevops_project.test_project.id
  name       = "Long-Running-Pipeline"
  path       = "\\Test"

  ci_trigger {
    use_yaml = true
  }

  repository {
    repo_type   = "TfsGit"
    repo_id     = azuredevops_git_repository.test_repo.id
    branch_name = "refs/heads/master"
    yml_path    = "long-running-pipeline.yml"
  }

  variable_groups = [
    azuredevops_variable_group.test_vars.id
  ]

  depends_on = [
    azuredevops_git_repository_file.long_running_pipeline_file,
    azuredevops_pipeline_authorization.test_auth
  ]
}

# Outputs
output "project_name" {
  value = azuredevops_project.test_project.name
}

output "project_url" {
  value = "https://dev.azure.com/${var.azure_devops_org}/${azuredevops_project.test_project.name}"
}

output "agent_pool_name" {
  value = azuredevops_agent_pool.test_pool.name
}
