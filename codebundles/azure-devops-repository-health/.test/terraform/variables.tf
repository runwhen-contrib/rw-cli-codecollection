variable "azure_devops_org" {
  description = "Azure DevOps organization name"
  type        = string
}

variable "azure_devops_org_url" {
  description = "Azure DevOps organization URL"
  type        = string
}

variable "resource_group" {
  description = "Azure resource group name for test resources"
  type        = string
}

variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "East US"
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default = {
    Environment = "test"
    Purpose     = "repository-health-testing"
  }
}

variable "project_name" {
  description = "Name for the test Azure DevOps project"
  type        = string
  default     = "repository-health-test-project"
}

variable "test_repositories" {
  description = "Configuration for test repositories with different scenarios"
  type = map(object({
    name                    = string
    description            = string
    branch_policies        = object({
      require_reviewers           = bool
      reviewer_count             = number
      creator_can_approve        = bool
      reset_votes_on_push        = bool
      require_build_validation   = bool
    })
    permissions            = object({
      excessive_permissions = bool
      public_read          = bool
    })
    test_scenario          = string
  }))
  default = {
    unprotected = {
      name        = "test-unprotected-repo"
      description = "Repository with no branch protection policies for testing security issues"
      branch_policies = {
        require_reviewers         = false
        reviewer_count           = 0
        creator_can_approve      = true
        reset_votes_on_push      = false
        require_build_validation = false
      }
      permissions = {
        excessive_permissions = false
        public_read          = false
      }
      test_scenario = "unprotected"
    }
    weak_security = {
      name        = "test-weak-security-repo"
      description = "Repository with weak security configuration"
      branch_policies = {
        require_reviewers         = true
        reviewer_count           = 1
        creator_can_approve      = true
        reset_votes_on_push      = false
        require_build_validation = false
      }
      permissions = {
        excessive_permissions = false
        public_read          = false
      }
      test_scenario = "weak_security"
    }
    overpermissioned = {
      name        = "test-overpermissioned-repo"
      description = "Repository with excessive permissions"
      branch_policies = {
        require_reviewers         = true
        reviewer_count           = 2
        creator_can_approve      = false
        reset_votes_on_push      = true
        require_build_validation = true
      }
      permissions = {
        excessive_permissions = true
        public_read          = true
      }
      test_scenario = "overpermissioned"
    }
    no_builds = {
      name        = "test-no-builds-repo"
      description = "Repository without build pipelines for testing code quality issues"
      branch_policies = {
        require_reviewers         = true
        reviewer_count           = 2
        creator_can_approve      = false
        reset_votes_on_push      = true
        require_build_validation = false
      }
      permissions = {
        excessive_permissions = false
        public_read          = false
      }
      test_scenario = "no_builds"
    }
    failing_builds = {
      name        = "test-failing-builds-repo"
      description = "Repository with high build failure rate"
      branch_policies = {
        require_reviewers         = true
        reviewer_count           = 2
        creator_can_approve      = false
        reset_votes_on_push      = true
        require_build_validation = true
      }
      permissions = {
        excessive_permissions = false
        public_read          = false
      }
      test_scenario = "failing_builds"
    }
    poor_structure = {
      name        = "test-poor-structure-repo"
      description = "Repository with poor structure and naming conventions"
      branch_policies = {
        require_reviewers         = true
        reviewer_count           = 2
        creator_can_approve      = false
        reset_votes_on_push      = true
        require_build_validation = true
      }
      permissions = {
        excessive_permissions = false
        public_read          = false
      }
      test_scenario = "poor_structure"
    }
    abandoned_prs = {
      name        = "test-abandoned-prs-repo"
      description = "Repository with abandoned pull requests"
      branch_policies = {
        require_reviewers         = true
        reviewer_count           = 2
        creator_can_approve      = false
        reset_votes_on_push      = true
        require_build_validation = true
      }
      permissions = {
        excessive_permissions = false
        public_read          = false
      }
      test_scenario = "abandoned_prs"
    }
    single_reviewer = {
      name        = "test-single-reviewer-repo"
      description = "Repository with single reviewer bottleneck"
      branch_policies = {
        require_reviewers         = true
        reviewer_count           = 1
        creator_can_approve      = false
        reset_votes_on_push      = true
        require_build_validation = true
      }
      permissions = {
        excessive_permissions = false
        public_read          = false
      }
      test_scenario = "single_reviewer"
    }
    quick_merges = {
      name        = "test-quick-merges-repo"
      description = "Repository with quick merge patterns"
      branch_policies = {
        require_reviewers         = true
        reviewer_count           = 1
        creator_can_approve      = false
        reset_votes_on_push      = false
        require_build_validation = false
      }
      permissions = {
        excessive_permissions = false
        public_read          = false
      }
      test_scenario = "quick_merges"
    }
    large_repo = {
      name        = "test-large-repo"
      description = "Repository with size and performance issues"
      branch_policies = {
        require_reviewers         = true
        reviewer_count           = 2
        creator_can_approve      = false
        reset_votes_on_push      = true
        require_build_validation = true
      }
      permissions = {
        excessive_permissions = false
        public_read          = false
      }
      test_scenario = "large_repo"
    }
    excessive_branches = {
      name        = "test-excessive-branches-repo"
      description = "Repository with too many branches"
      branch_policies = {
        require_reviewers         = true
        reviewer_count           = 2
        creator_can_approve      = false
        reset_votes_on_push      = true
        require_build_validation = true
      }
      permissions = {
        excessive_permissions = false
        public_read          = false
      }
      test_scenario = "excessive_branches"
    }
    frequent_pushes = {
      name        = "test-frequent-pushes-repo"
      description = "Repository with frequent small pushes"
      branch_policies = {
        require_reviewers         = true
        reviewer_count           = 2
        creator_can_approve      = false
        reset_votes_on_push      = true
        require_build_validation = true
      }
      permissions = {
        excessive_permissions = false
        public_read          = false
      }
      test_scenario = "frequent_pushes"
    }
  }
}

variable "test_users" {
  description = "Test users for collaboration scenarios"
  type = list(object({
    name  = string
    email = string
    role  = string
  }))
  default = [
    {
      name  = "Test Developer 1"
      email = "dev1@example.com"
      role  = "developer"
    },
    {
      name  = "Test Developer 2"
      email = "dev2@example.com"
      role  = "developer"
    },
    {
      name  = "Test Reviewer"
      email = "reviewer@example.com"
      role  = "reviewer"
    }
  ]
} 