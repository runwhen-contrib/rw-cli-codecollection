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

# Azure DevOps Project for repository health testing
resource "azuredevops_project" "test_project" {
  name               = "${var.project_name}-${random_string.suffix.result}"
  description        = "Test project for repository health monitoring validation"
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

# Create test repositories with different configurations
resource "azuredevops_git_repository" "test_repos" {
  for_each = var.test_repositories

  project_id = azuredevops_project.test_project.id
  name       = each.value.name

  initialization {
    init_type = "Clean"
  }

  lifecycle {
    ignore_changes = [
      initialization,
    ]
  }
}

# Branch policies for repositories that require them
resource "azuredevops_branch_policy_min_reviewers" "test_reviewers" {
  for_each = {
    for k, v in var.test_repositories : k => v
    if v.branch_policies.require_reviewers
  }

  project_id = azuredevops_project.test_project.id

  enabled  = true
  blocking = true

  settings {
    reviewer_count                         = each.value.branch_policies.reviewer_count
    submitter_can_vote                    = each.value.branch_policies.creator_can_approve
    last_pusher_cannot_approve            = !each.value.branch_policies.creator_can_approve
    allow_completion_with_rejects_or_waits = false
    on_push_reset_approved_votes          = each.value.branch_policies.reset_votes_on_push

    scope {
      repository_id  = azuredevops_git_repository.test_repos[each.key].id
      repository_ref = azuredevops_git_repository.test_repos[each.key].default_branch
      match_type     = "Exact"
    }
  }

  depends_on = [azuredevops_git_repository.test_repos]
}

# Build validation policies for repositories that require them
resource "azuredevops_branch_policy_build_validation" "test_build_validation" {
  for_each = {
    for k, v in var.test_repositories : k => v
    if v.branch_policies.require_build_validation && contains(["weak_security", "overpermissioned", "failing_builds", "poor_structure", "abandoned_prs", "single_reviewer", "large_repo", "excessive_branches", "frequent_pushes"], k)
  }

  project_id = azuredevops_project.test_project.id

  enabled  = true
  blocking = true

  settings {
    display_name        = "Test Build Validation"
    build_definition_id = azuredevops_build_definition.test_builds[each.key].id
    valid_duration      = 720
    filename_patterns = [
      "/azure-pipelines.yml"
    ]

    scope {
      repository_id  = azuredevops_git_repository.test_repos[each.key].id
      repository_ref = azuredevops_git_repository.test_repos[each.key].default_branch
      match_type     = "Exact"
    }
  }

  depends_on = [
    azuredevops_git_repository.test_repos,
    azuredevops_build_definition.test_builds
  ]
}

# Build definitions for testing different scenarios
resource "azuredevops_build_definition" "test_builds" {
  for_each = {
    for k, v in var.test_repositories : k => v
    if contains(["failing_builds", "poor_structure", "abandoned_prs", "single_reviewer", "large_repo", "excessive_branches", "frequent_pushes"], k)
  }

  project_id = azuredevops_project.test_project.id
  name       = "${each.value.name}-build"

  ci_trigger {
    use_yaml = true
  }

  repository {
    repo_type   = "TfsGit"
    repo_id     = azuredevops_git_repository.test_repos[each.key].id
    branch_name = azuredevops_git_repository.test_repos[each.key].default_branch
    yml_path    = "azure-pipelines.yml"
  }

  depends_on = [azuredevops_git_repository.test_repos]
}

# Create pipeline files for different test scenarios
resource "local_file" "success_pipeline" {
  for_each = {
    for k, v in var.test_repositories : k => v
    if contains(["poor_structure", "abandoned_prs", "single_reviewer", "large_repo", "excessive_branches", "frequent_pushes"], k)
  }

  content = templatefile("${path.module}/pipeline-templates/success-pipeline.yml", {
    scenario = each.value.test_scenario
  })
  filename = "${path.module}/generated-files/${each.key}-success-pipeline.yml"
}

resource "local_file" "failing_pipeline" {
  for_each = {
    for k, v in var.test_repositories : k => v
    if k == "failing_builds"
  }

  content = templatefile("${path.module}/pipeline-templates/failing-pipeline.yml", {
    scenario = each.value.test_scenario
  })
  filename = "${path.module}/generated-files/${each.key}-failing-pipeline.yml"
}

# Create test data files for large repository scenario
resource "local_file" "large_files" {
  for_each = {
    for k, v in var.test_repositories : k => v
    if k == "large_repo"
  }

  content  = "# Large test file for repository size testing\n${join("\n", [for i in range(10000) : "This is line ${i} of test data for creating a large repository to test size monitoring."])}"
  filename = "${path.module}/generated-files/${each.key}-large-file.txt"
}

# Create branch creation scripts for excessive branches scenario
resource "local_file" "branch_creation_script" {
  for_each = {
    for k, v in var.test_repositories : k => v
    if k == "excessive_branches"
  }

  content = templatefile("${path.module}/scripts/create-branches.sh", {
    repo_name    = each.value.name
    project_name = azuredevops_project.test_project.name
    org_url      = var.azure_devops_org_url
  })
  filename = "${path.module}/generated-files/${each.key}-create-branches.sh"
}

# Create PR creation scripts for collaboration testing
resource "local_file" "pr_creation_script" {
  for_each = {
    for k, v in var.test_repositories : k => v
    if contains(["abandoned_prs", "single_reviewer", "quick_merges"], k)
  }

  content = templatefile("${path.module}/scripts/create-prs.sh", {
    repo_name    = each.value.name
    project_name = azuredevops_project.test_project.name
    org_url      = var.azure_devops_org_url
    scenario     = each.value.test_scenario
  })
  filename = "${path.module}/generated-files/${each.key}-create-prs.sh"
}

# Create commit history scripts for frequent pushes scenario
resource "local_file" "commit_history_script" {
  for_each = {
    for k, v in var.test_repositories : k => v
    if k == "frequent_pushes"
  }

  content = templatefile("${path.module}/scripts/create-commits.sh", {
    repo_name    = each.value.name
    project_name = azuredevops_project.test_project.name
    org_url      = var.azure_devops_org_url
  })
  filename = "${path.module}/generated-files/${each.key}-create-commits.sh"
}

# Repository permissions for overpermissioned scenario
resource "azuredevops_git_permissions" "overpermissioned" {
  for_each = {
    for k, v in var.test_repositories : k => v
    if v.permissions.excessive_permissions
  }

  project_id    = azuredevops_project.test_project.id
  repository_id = azuredevops_git_repository.test_repos[each.key].id
  principal     = "Everyone"

  permissions = {
    Administer        = "Allow"
    GenericRead       = "Allow"
    GenericContribute = "Allow"
    ForcePush         = "Allow"
    CreateBranch      = "Allow"
    CreateTag         = "Allow"
    ManageNote        = "Allow"
    PolicyExempt      = "Allow"
    RemoveOthersLocks = "Allow"
    RenameRepository  = "Allow"
  }

  depends_on = [azuredevops_git_repository.test_repos]
}

# Create validation scripts
resource "local_file" "validation_scripts" {
  for_each = toset([
    "validate-security-tests",
    "validate-quality-tests", 
    "validate-collaboration-tests",
    "validate-performance-tests"
  ])

  content = templatefile("${path.module}/scripts/${each.key}.sh", {
    project_name = azuredevops_project.test_project.name
    org_url      = var.azure_devops_org_url
    repositories = var.test_repositories
  })
  filename = "${path.module}/../${each.key}.sh"
}

# Make validation scripts executable
resource "null_resource" "make_scripts_executable" {
  for_each = toset([
    "validate-security-tests",
    "validate-quality-tests",
    "validate-collaboration-tests", 
    "validate-performance-tests"
  ])

  provisioner "local-exec" {
    command = "chmod +x ${path.module}/../${each.key}.sh"
  }

  depends_on = [local_file.validation_scripts]
}

# Create setup script for post-terraform configuration
resource "local_file" "setup_test_data" {
  content = templatefile("${path.module}/scripts/setup-test-data.sh", {
    project_name = azuredevops_project.test_project.name
    org_url      = var.azure_devops_org_url
    repositories = var.test_repositories
  })
  filename = "${path.module}/../setup-test-data.sh"
}

resource "null_resource" "make_setup_executable" {
  provisioner "local-exec" {
    command = "chmod +x ${path.module}/../setup-test-data.sh"
  }

  depends_on = [local_file.setup_test_data]
} 