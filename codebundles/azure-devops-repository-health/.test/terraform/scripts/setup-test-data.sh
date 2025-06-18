#!/bin/bash

# Setup script for generating test data for repository health scenarios
# This script creates realistic test data to validate repository health monitoring

set -e

PROJECT_NAME="${project_name}"
ORG_URL="${org_url}"

echo "=== Setting Up Test Data for Repository Health Scenarios ==="
echo "Project: $PROJECT_NAME"
echo "Organization: $ORG_URL"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check prerequisites
check_prerequisites() {
    echo "Checking prerequisites..."
    
    if ! command -v az &> /dev/null; then
        echo -e "${RED}✗ Azure CLI not found. Please install Azure CLI.${NC}"
        exit 1
    fi
    
    if ! az extension list | grep -q azure-devops; then
        echo "Installing Azure DevOps extension..."
        az extension add --name azure-devops
    fi
    
    if [ -z "$AZURE_DEVOPS_EXT_PAT" ]; then
        echo -e "${RED}✗ AZURE_DEVOPS_EXT_PAT environment variable not set.${NC}"
        echo "Please set your Azure DevOps Personal Access Token:"
        echo "export AZURE_DEVOPS_EXT_PAT=your-pat-token"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Prerequisites checked${NC}"
}

# Create test branches for excessive branches scenario
create_excessive_branches() {
    local repo_name="$1"
    echo -e "${BLUE}Creating excessive branches for $repo_name...${NC}"
    
    # Create 50+ branches with various naming patterns
    local branch_names=(
        "feature/user-authentication"
        "feature/payment-integration"
        "feature/notification-system"
        "bugfix/login-issue"
        "bugfix/payment-error"
        "hotfix/security-patch"
        "release/v1.0.0"
        "release/v1.1.0"
        "experimental/new-ui"
        "experimental/performance-test"
        "dev/john-doe-work"
        "dev/jane-smith-feature"
        "temp/quick-fix"
        "temp/testing-branch"
        "old/legacy-code"
        "old/deprecated-feature"
        "backup/before-refactor"
        "backup/old-implementation"
        "test/integration-tests"
        "test/unit-tests"
        "docs/api-documentation"
        "docs/user-guide"
        "config/environment-setup"
        "config/deployment-scripts"
        "prototype/new-architecture"
        "prototype/ui-redesign"
        "spike/research-task"
        "spike/technology-evaluation"
        "wip/work-in-progress"
        "wip/incomplete-feature"
        "personal/developer1-branch"
        "personal/developer2-branch"
        "abandoned/old-feature"
        "abandoned/cancelled-work"
        "stale/six-months-old"
        "stale/one-year-old"
        "random/branch1"
        "random/branch2"
        "random/branch3"
        "random/branch4"
        "random/branch5"
        "feature/TICKET-123"
        "feature/TICKET-456"
        "feature/TICKET-789"
        "bugfix/BUG-001"
        "bugfix/BUG-002"
        "hotfix/CRITICAL-001"
        "hotfix/CRITICAL-002"
        "release/2023.1"
        "release/2023.2"
        "release/2024.1"
    )
    
    for branch in "$${branch_names[@]}"; do
        az repos ref create \
            --name "refs/heads/$branch" \
            --repository "$repo_name" \
            --project "$PROJECT_NAME" \
            --organization "$ORG_URL" \
            --object-id $(az repos ref list --repository "$repo_name" --project "$PROJECT_NAME" --organization "$ORG_URL" --query "[?name=='refs/heads/main'].objectId" -o tsv) \
            2>/dev/null || true
    done
    
    echo -e "${GREEN}✓ Created excessive branches for $repo_name${NC}"
}

# Create test pull requests for collaboration scenarios
create_test_pull_requests() {
    local repo_name="$1"
    local scenario="$2"
    echo -e "${BLUE}Creating test pull requests for $repo_name ($scenario)...${NC}"
    
    case $scenario in
        "abandoned_prs")
            # Create old, abandoned PRs
            create_abandoned_prs "$repo_name"
            ;;
        "single_reviewer")
            # Create PRs all reviewed by same person
            create_single_reviewer_prs "$repo_name"
            ;;
        "quick_merges")
            # Create PRs that were merged very quickly
            create_quick_merge_prs "$repo_name"
            ;;
    esac
}

create_abandoned_prs() {
    local repo_name="$1"
    echo "Creating abandoned pull requests..."
    
    # Note: Creating actual PRs with specific dates requires more complex setup
    # This is a placeholder for the concept - in real testing, you'd need to:
    # 1. Create branches with commits
    # 2. Create PRs from those branches
    # 3. Leave them open for extended periods
    
    echo -e "${YELLOW}⚠ Abandoned PR creation requires manual setup or extended time${NC}"
    echo "Consider creating PRs manually and leaving them open for testing"
}

create_single_reviewer_prs() {
    local repo_name="$1"
    echo "Setting up single reviewer scenario..."
    
    echo -e "${YELLOW}⚠ Single reviewer PR setup requires manual PR creation${NC}"
    echo "Create multiple PRs and have them all reviewed by the same person"
}

create_quick_merge_prs() {
    local repo_name="$1"
    echo "Setting up quick merge scenario..."
    
    echo -e "${YELLOW}⚠ Quick merge PR setup requires manual PR creation and immediate merging${NC}"
    echo "Create PRs and merge them within minutes for testing"
}

# Create large files for repository size testing
create_large_files() {
    local repo_name="$1"
    echo -e "${BLUE}Creating large files for $repo_name...${NC}"
    
    # Clone repository temporarily
    local temp_dir=$(mktemp -d)
    cd "$temp_dir"
    
    git clone "$ORG_URL/$PROJECT_NAME/_git/$repo_name" .
    
    # Create large files
    echo "Creating large test files..."
    
    # Create a 10MB file
    dd if=/dev/zero of=large-file-10mb.bin bs=1024 count=10240 2>/dev/null
    
    # Create multiple medium files
    for i in {1..5}; do
        dd if=/dev/zero of="medium-file-$i.bin" bs=1024 count=2048 2>/dev/null
    done
    
    # Create a large text file with repetitive content
    for i in {1..100000}; do
        echo "This is line $i of a large text file for testing repository size monitoring." >> large-text-file.txt
    done
    
    # Add and commit files
    git add .
    git commit -m "Add large files for repository size testing"
    git push origin main
    
    cd - > /dev/null
    rm -rf "$temp_dir"
    
    echo -e "${GREEN}✓ Created large files for $repo_name${NC}"
}

# Create frequent commits for commit pattern testing
create_frequent_commits() {
    local repo_name="$1"
    echo -e "${BLUE}Creating frequent commits for $repo_name...${NC}"
    
    # Clone repository temporarily
    local temp_dir=$(mktemp -d)
    cd "$temp_dir"
    
    git clone "$ORG_URL/$PROJECT_NAME/_git/$repo_name" .
    
    # Create many small commits
    for i in {1..50}; do
        echo "Small change $i" >> frequent-changes.txt
        git add frequent-changes.txt
        git commit -m "Small change $i - frequent commit pattern"
        
        # Add small delay to simulate real commits over time
        sleep 1
    done
    
    git push origin main
    
    cd - > /dev/null
    rm -rf "$temp_dir"
    
    echo -e "${GREEN}✓ Created frequent commits for $repo_name${NC}"
}

# Create poor structure for structure testing
create_poor_structure() {
    local repo_name="$1"
    echo -e "${BLUE}Creating poor structure for $repo_name...${NC}"
    
    # Clone repository temporarily
    local temp_dir=$(mktemp -d)
    cd "$temp_dir"
    
    git clone "$ORG_URL/$PROJECT_NAME/_git/$repo_name" .
    
    # Create poorly structured directories and files
    mkdir -p "random_stuff/more_random/deeply/nested/structure"
    mkdir -p "UPPERCASE_DIR/MixedCase_Dir/lowercase_dir"
    mkdir -p "temp/tmp/temporary/temp_files"
    mkdir -p "old/old_stuff/legacy/deprecated"
    
    # Create files with poor naming
    touch "file1.txt"
    touch "FILE2.TXT"
    touch "File_3.txt"
    touch "file-4.txt"
    touch "file.backup.old.txt"
    touch "temp_file_delete_me.txt"
    touch "TODO_FIX_THIS.txt"
    touch "URGENT_IMPORTANT.txt"
    touch "random_stuff/random_file.txt"
    touch "UPPERCASE_DIR/SHOUTING_FILE.TXT"
    
    # Create files without proper extensions
    touch "config_file"
    touch "script_file"
    touch "data_file"
    
    # Add and commit
    git add .
    git commit -m "Add poorly structured files and directories"
    git push origin main
    
    cd - > /dev/null
    rm -rf "$temp_dir"
    
    echo -e "${GREEN}✓ Created poor structure for $repo_name${NC}"
}

# Main setup function
setup_repository_data() {
    local repo_config="$1"
    local repo_name=$(echo "$repo_config" | jq -r '.name')
    local scenario=$(echo "$repo_config" | jq -r '.test_scenario')
    
    echo -e "${BLUE}Setting up data for $repo_name (scenario: $scenario)...${NC}"
    
    case $scenario in
        "excessive_branches")
            create_excessive_branches "$repo_name"
            ;;
        "abandoned_prs"|"single_reviewer"|"quick_merges")
            create_test_pull_requests "$repo_name" "$scenario"
            ;;
        "large_repo")
            create_large_files "$repo_name"
            ;;
        "frequent_pushes")
            create_frequent_commits "$repo_name"
            ;;
        "poor_structure")
            create_poor_structure "$repo_name"
            ;;
        *)
            echo -e "${YELLOW}⚠ No specific data setup for scenario: $scenario${NC}"
            ;;
    esac
}

# Main execution
main() {
    check_prerequisites
    
    echo "Starting test data setup..."
    echo ""
    
    # Repository configurations (this would be populated by Terraform template)
    %{ for k, v in repositories ~}
    echo "Setting up ${v.name} for ${v.test_scenario} scenario..."
    setup_repository_data '${jsonencode(v)}'
    echo ""
    %{ endfor ~}
    
    echo -e "${GREEN}=== Test Data Setup Complete ===${NC}"
    echo ""
    echo "Next steps:"
    echo "1. Wait a few minutes for Azure DevOps to process the changes"
    echo "2. Run repository health tests: task test-all-scenarios"
    echo "3. Validate results: task validate-results"
    echo ""
    echo "Note: Some scenarios (like abandoned PRs) require manual setup or time to develop realistic patterns."
}

# Run main function
main "$@" 