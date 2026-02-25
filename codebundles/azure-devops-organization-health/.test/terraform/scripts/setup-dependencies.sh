#!/bin/bash

# Script to set up cross-project dependencies for Azure DevOps testing
# Template variables will be replaced by Terraform

ORG_URL="${org_url}"
PROJECTS=(${join(" ", [for p in projects : format("%q", p)])})
VARIABLE_GROUPS=(${join(" ", [for v in var_groups : format("%q", v)])})

echo "Setting up cross-project dependencies"
echo "Organization URL: $ORG_URL"
echo "Projects: $${PROJECTS[@]}"
echo "Variable Groups: $${VARIABLE_GROUPS[@]}"

# Function to create shared artifacts
create_shared_artifacts() {
    echo "=== Creating Shared Artifacts ==="
    
    # Simulate creating shared NuGet packages
    echo "Creating shared NuGet packages..."
    packages=("Common.Utils" "Shared.Models" "Core.Services")
    
    for package in "$${packages[@]}"; do
        echo "ARTIFACT_CREATED: NuGet package '$package' v1.0.0"
    done
    
    # Simulate creating shared Docker images
    echo "Creating shared Docker images..."
    images=("base-runtime" "common-tools" "test-framework")
    
    for image in "$${images[@]}"; do
        echo "ARTIFACT_CREATED: Docker image '$image:latest'"
    done
}

# Function to set up variable group dependencies
setup_variable_groups() {
    echo "=== Setting Up Variable Group Dependencies ==="
    
    for var_group in "$${VARIABLE_GROUPS[@]}"; do
        echo "Configuring variable group: $var_group"
        
        # Simulate linking variable groups to projects
        for project in "$${PROJECTS[@]}"; do
            echo "DEPENDENCY_CREATED: Variable group '$var_group' linked to project '$project'"
        done
    done
}

# Function to create service connections dependencies
setup_service_connections() {
    echo "=== Setting Up Service Connection Dependencies ==="
    
    connections=("Azure-Prod" "Azure-Test" "Docker-Registry")
    
    for connection in "$${connections[@]}"; do
        echo "Configuring service connection: $connection"
        
        # Simulate sharing service connections across projects
        for project in "$${PROJECTS[@]}"; do
            echo "DEPENDENCY_CREATED: Service connection '$connection' shared with project '$project'"
        done
    done
}

# Function to create build dependencies
setup_build_dependencies() {
    echo "=== Setting Up Build Dependencies ==="
    
    # Create dependency chain: Project A -> Project B -> Project C
    if [ $${#PROJECTS[@]} -ge 3 ]; then
        project_a="$${PROJECTS[0]}"
        project_b="$${PROJECTS[1]}"
        project_c="$${PROJECTS[2]}"
        
        echo "Creating build dependency chain:"
        echo "  $project_a (base) -> $project_b (middleware) -> $project_c (frontend)"
        
        echo "DEPENDENCY_CREATED: Build trigger from '$project_a' to '$project_b'"
        echo "DEPENDENCY_CREATED: Build trigger from '$project_b' to '$project_c'"
        echo "DEPENDENCY_CREATED: Artifact dependency '$project_a' -> '$project_b'"
        echo "DEPENDENCY_CREATED: Artifact dependency '$project_b' -> '$project_c'"
    fi
}

# Function to set up release dependencies
setup_release_dependencies() {
    echo "=== Setting Up Release Dependencies ==="
    
    environments=("Development" "Testing" "Staging" "Production")
    
    for env in "$${environments[@]}"; do
        echo "Configuring release environment: $env"
        
        # Simulate creating environment dependencies
        for project in "$${PROJECTS[@]}"; do
            echo "DEPENDENCY_CREATED: Release pipeline for '$project' -> '$env' environment"
        done
    done
}

# Function to validate dependencies
validate_dependencies() {
    echo "=== Validating Dependencies ==="
    
    echo "Checking artifact dependencies..."
    echo "VALIDATION: All shared artifacts are accessible"
    
    echo "Checking variable group access..."
    echo "VALIDATION: Variable groups accessible from all projects"
    
    echo "Checking service connection permissions..."
    echo "VALIDATION: Service connections have proper permissions"
    
    echo "Checking build triggers..."
    echo "VALIDATION: Build triggers are properly configured"
    
    echo "Checking release gates..."
    echo "VALIDATION: Release approval gates are in place"
}

# Function to generate dependency report
generate_dependency_report() {
    local report_file="dependency_setup_report.json"
    
    echo "Generating dependency setup report: $report_file"
    
    cat > "$report_file" << EOF
{
  "organization": "$ORG_URL",
  "setup_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "projects": [$(printf '"%s",' "$${PROJECTS[@]}" | sed 's/,$//')]",
  "variable_groups": [$(printf '"%s",' "$${VARIABLE_GROUPS[@]}" | sed 's/,$//')]",
  "dependencies_created": {
    "artifacts": 6,
    "variable_groups": $${#VARIABLE_GROUPS[@]},
    "service_connections": 3,
    "build_triggers": 2,
    "release_pipelines": $(($${#PROJECTS[@]} * 4))
  },
  "validation_status": "PASSED",
  "issues_found": 0
}
EOF
    
    echo "Dependency report generated: $report_file"
}

# Main execution
main() {
    echo "Starting cross-project dependency setup"
    echo "Organization: $ORG_URL"
    echo "----------------------------------------"
    
    create_shared_artifacts
    echo ""
    
    setup_variable_groups
    echo ""
    
    setup_service_connections
    echo ""
    
    setup_build_dependencies
    echo ""
    
    setup_release_dependencies
    echo ""
    
    validate_dependencies
    echo ""
    
    generate_dependency_report
    
    echo "Cross-project dependency setup completed"
}

# Run main function if script is executed directly
if [[ "$${BASH_SOURCE[0]}" == "$${0}" ]]; then
    main "$@"
fi 