output "project_name" {
  description = "Name of the created Azure DevOps project"
  value       = azuredevops_project.test_project.name
}

output "project_id" {
  description = "ID of the created Azure DevOps project"
  value       = azuredevops_project.test_project.id
}

output "project_url" {
  description = "URL of the created Azure DevOps project"
  value       = "${var.azure_devops_org_url}/${azuredevops_project.test_project.name}"
}

output "devops_org" {
  description = "Azure DevOps organization name"
  value       = var.azure_devops_org
}

output "resource_group_name" {
  description = "Name of the created Azure resource group"
  value       = azurerm_resource_group.test.name
}

output "repository_urls" {
  description = "URLs of all created test repositories"
  value = {
    for k, repo in azuredevops_git_repository.test_repos : k => {
      name = repo.name
      url  = repo.remote_url
      web_url = "${var.azure_devops_org_url}/${azuredevops_project.test_project.name}/_git/${repo.name}"
      scenario = var.test_repositories[k].test_scenario
    }
  }
}

output "repository_details" {
  description = "Detailed information about test repositories and their configurations"
  value = {
    for k, v in var.test_repositories : k => {
      name = v.name
      description = v.description
      scenario = v.test_scenario
      branch_policies = v.branch_policies
      permissions = v.permissions
      repository_id = azuredevops_git_repository.test_repos[k].id
      default_branch = azuredevops_git_repository.test_repos[k].default_branch
    }
  }
}

output "build_definitions" {
  description = "Build definitions created for testing"
  value = {
    for k, build in azuredevops_build_definition.test_builds : k => {
      name = build.name
      id   = build.id
      repository = var.test_repositories[k].name
      scenario = var.test_repositories[k].test_scenario
    }
  }
}

output "test_scenarios_summary" {
  description = "Summary of all test scenarios and their expected outcomes"
  value = {
    security_tests = {
      unprotected = {
        repository = var.test_repositories.unprotected.name
        expected_issues = [
          "Missing Required Reviewers Policy",
          "Missing Build Validation Policy", 
          "Unprotected Default Branch"
        ]
        expected_health_score = "< 50"
        critical_investigation = true
      }
      weak_security = {
        repository = var.test_repositories.weak_security.name
        expected_issues = [
          "Insufficient Required Reviewers",
          "Creator Can Approve Own Changes",
          "Reviews Not Reset on New Changes"
        ]
        expected_health_score = "50-69"
        critical_investigation = false
      }
      overpermissioned = {
        repository = var.test_repositories.overpermissioned.name
        expected_issues = [
          "Excessive Repository Permissions",
          "Public Read Access Enabled"
        ]
        expected_health_score = "60-75"
        critical_investigation = false
      }
    }
    quality_tests = {
      no_builds = {
        repository = var.test_repositories.no_builds.name
        expected_issues = [
          "No Build Definitions Found",
          "No Test Results Found",
          "Missing Build Validation Policy"
        ]
        expected_health_score = "< 70"
        critical_investigation = true
      }
      failing_builds = {
        repository = var.test_repositories.failing_builds.name
        expected_issues = [
          "High Build Failure Rate",
          "Recent Build Failures"
        ]
        expected_health_score = "60-75"
        critical_investigation = false
      }
      poor_structure = {
        repository = var.test_repositories.poor_structure.name
        expected_issues = [
          "Poor Branch Naming Conventions",
          "No Standard Workflow Branches"
        ]
        expected_health_score = "70-80"
        critical_investigation = false
      }
    }
    collaboration_tests = {
      abandoned_prs = {
        repository = var.test_repositories.abandoned_prs.name
        expected_issues = [
          "High Pull Request Abandonment Rate",
          "Long-Lived Pull Requests"
        ]
        expected_health_score = "50-70"
        critical_investigation = false
      }
      single_reviewer = {
        repository = var.test_repositories.single_reviewer.name
        expected_issues = [
          "Single Reviewer Bottleneck",
          "Review Process Inefficiency"
        ]
        expected_health_score = "60-75"
        critical_investigation = false
      }
      quick_merges = {
        repository = var.test_repositories.quick_merges.name
        expected_issues = [
          "High Rate of Quick Merges",
          "Insufficient Review Time"
        ]
        expected_health_score = "65-80"
        critical_investigation = false
      }
    }
    performance_tests = {
      large_repo = {
        repository = var.test_repositories.large_repo.name
        expected_issues = [
          "Repository Size Exceeds Threshold",
          "Large Repository May Need Git LFS"
        ]
        expected_health_score = "70-85"
        critical_investigation = false
      }
      excessive_branches = {
        repository = var.test_repositories.excessive_branches.name
        expected_issues = [
          "Excessive Number of Branches",
          "Stale Branches Detected"
        ]
        expected_health_score = "60-80"
        critical_investigation = false
      }
      frequent_pushes = {
        repository = var.test_repositories.frequent_pushes.name
        expected_issues = [
          "High Frequency of Small Commits",
          "Workflow Efficiency Issues"
        ]
        expected_health_score = "70-85"
        critical_investigation = false
      }
    }
  }
}

output "validation_commands" {
  description = "Commands to run for validating test scenarios"
  value = {
    setup_test_data = "cd .test && ./setup-test-data.sh"
    validate_security = "cd .test && ./validate-security-tests.sh"
    validate_quality = "cd .test && ./validate-quality-tests.sh"
    validate_collaboration = "cd .test && ./validate-collaboration-tests.sh"
    validate_performance = "cd .test && ./validate-performance-tests.sh"
    run_all_tests = "cd .test && task test-all-scenarios"
  }
}

output "next_steps" {
  description = "Next steps after infrastructure creation"
  value = [
    "1. Run setup script: cd .test && ./setup-test-data.sh",
    "2. Wait for test data generation to complete (5-10 minutes)",
    "3. Run repository health tests: task test-all-scenarios",
    "4. Validate results: task validate-results",
    "5. Review test outputs in .test/output/ directories",
    "6. Clean up when done: task clean"
  ]
} 