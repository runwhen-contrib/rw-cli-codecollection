#!/bin/bash

# GCP Cost Report by Service and Project
# Generates a detailed cost breakdown for the last 30 days

# Logging function
log() {
    echo "💰 [$(date '+%H:%M:%S')] $*" >&2
}

# Environment Variables
PROJECT_IDS="${GCP_PROJECT_IDS}"
log "DEBUG: Initial GCP_PROJECT_IDS value: '${GCP_PROJECT_IDS}'"
log "DEBUG: Initial PROJECT_IDS value: '$PROJECT_IDS'"
# Normalize empty strings - remove quotes and trim whitespace
PROJECT_IDS=$(echo "$PROJECT_IDS" | sed 's/^"//;s/"$//' | xargs)
log "DEBUG: After normalization PROJECT_IDS value: '$PROJECT_IDS'"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-table}"  # table, csv, json
REPORT_FILE="${REPORT_FILE:-gcp_cost_report.txt}"
CSV_FILE="${CSV_FILE:-gcp_cost_report.csv}"
JSON_FILE="${JSON_FILE:-gcp_cost_report.json}"
ISSUES_FILE="${ISSUES_FILE:-gcp_cost_issues.json}"
COST_BUDGET="${GCP_COST_BUDGET:-}"  # Optional budget threshold
PROJECT_COST_THRESHOLD_PERCENT="${GCP_PROJECT_COST_THRESHOLD_PERCENT:-}"  # Optional % threshold for individual projects

# Check if bq command is available
check_bq_available() {
    if command -v bq &> /dev/null; then
        return 0
    fi
    # Also check common installation paths
    if [[ -f "$HOME/google-cloud-sdk/bin/bq" ]] || [[ -f "/usr/local/bin/bq" ]] || [[ -f "/opt/google-cloud-sdk/bin/bq" ]]; then
        return 0
    fi
    return 1
}

# Check if Python BigQuery client is available
check_python_bq_available() {
    if command -v python3 &> /dev/null || command -v python &> /dev/null; then
        local python_cmd=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
        if $python_cmd -c "from google.cloud import bigquery" 2>/dev/null; then
            echo "$python_cmd"
            return 0
        fi
    fi
    return 1
}

# Check for any BigQuery access method
check_bigquery_access() {
    # Always prefer bq CLI if available
    if check_bq_available; then
        # Verify bq actually works by checking version
        if bq version &>/dev/null || bq --version &>/dev/null || bq help &>/dev/null; then
            echo "bq"
            return 0
        else
            # Log function may not be available yet, use echo to stderr
            echo "⚠️  'bq' command found but not working properly, falling back to Python" >&2
        fi
    fi
    
    local python_cmd=$(check_python_bq_available)
    if [[ -n "$python_cmd" ]]; then
        echo "python"
        return 0
    fi
    
    return 1
}

# Python helper: List datasets in a project
python_list_datasets() {
    local project_id="$1"
    local python_cmd=$(check_python_bq_available)
    [[ -z "$python_cmd" ]] && return 1
    
    local project_arg=""
    if [[ -n "$project_id" ]]; then
        project_arg="project='$project_id'"
    fi
    
    if [[ -n "$project_id" ]]; then
        $python_cmd -c "
from google.cloud import bigquery
from google.api_core import exceptions
import json
import sys

try:
    client = bigquery.Client(project='$project_id')
    datasets = list(client.list_datasets())
    result = [{'datasetId': d.dataset_id} for d in datasets]
    print(json.dumps(result))
except exceptions.Forbidden as e:
    sys.stderr.write(f'Permission denied: {e}\n')
    sys.exit(1)
except exceptions.NotFound as e:
    sys.stderr.write(f'Project not found: {e}\n')
    sys.exit(1)
except Exception as e:
    sys.stderr.write(f'Error listing datasets: {e}\n')
    sys.exit(1)
" 2>&1
    else
        $python_cmd -c "
from google.cloud import bigquery
from google.api_core import exceptions
import json
import sys

try:
    client = bigquery.Client()
    datasets = list(client.list_datasets())
    result = [{'datasetId': d.dataset_id} for d in datasets]
    print(json.dumps(result))
except exceptions.Forbidden as e:
    sys.stderr.write(f'Permission denied: {e}\n')
    sys.exit(1)
except exceptions.NotFound as e:
    sys.stderr.write(f'Project not found: {e}\n')
    sys.exit(1)
except Exception as e:
    sys.stderr.write(f'Error listing datasets: {e}\n')
    sys.exit(1)
" 2>&1
    fi
}

# Python helper: List tables in a dataset
python_list_tables() {
    local project_id="$1"
    local dataset_id="$2"
    local python_cmd=$(check_python_bq_available)
    [[ -z "$python_cmd" ]] && return 1
    
    $python_cmd -c "
from google.cloud import bigquery
from google.api_core import exceptions
import json
import sys

try:
    client = bigquery.Client(project='$project_id')
    dataset_ref = client.dataset('$dataset_id')
    tables = list(client.list_tables(dataset_ref))
    result = [{'tableId': t.table_id} for t in tables]
    print(json.dumps(result))
except exceptions.Forbidden as e:
    sys.stderr.write(f'Permission denied: {e}\n')
    sys.exit(1)
except exceptions.NotFound as e:
    sys.stderr.write(f'Dataset not found: {e}\n')
    sys.exit(1)
except Exception as e:
    sys.stderr.write(f'Error listing tables: {e}\n')
    sys.exit(1)
" 2>&1
}

# Python helper: Get table info and verify schema
python_check_table() {
    local project_id="$1"
    local dataset_id="$2"
    local table_id="$3"
    local python_cmd=$(check_python_bq_available)
    [[ -z "$python_cmd" ]] && return 1
    
    $python_cmd -c "
from google.cloud import bigquery
import json
import sys

try:
    client = bigquery.Client(project='$project_id')
    table_ref = client.dataset('$dataset_id').table('$table_id')
    table = client.get_table(table_ref)
    
    # Check for required fields
    field_names = [field.name for field in table.schema]
    has_cost = 'cost' in field_names
    has_usage_start = 'usage_start_time' in field_names
    
    if has_cost and has_usage_start:
        print(json.dumps({'valid': True, 'projectId': table.project, 'datasetId': table.dataset_id, 'tableId': table.table_id}))
        sys.exit(0)
    else:
        sys.exit(1)
except Exception as e:
    sys.stderr.write(f'Error: {e}\n')
    sys.exit(1)
" 2>/dev/null
}

# Get date range (last 30 days)
get_date_range() {
    local end_date=$(date -u +"%Y-%m-%d")
    local start_date=$(date -u -d '30 days ago' +"%Y-%m-%d" 2>/dev/null || date -u -v-30d +"%Y-%m-%d" 2>/dev/null)
    
    echo "$start_date|$end_date"
}

# Get project name from ID
get_project_name() {
    local project_id="$1"
    local project_name=$(gcloud projects describe "$project_id" --format="value(name)" 2>/dev/null || echo "")
    if [[ -z "$project_name" ]]; then
        # Fallback to ID if name not available
        echo "$project_id"
    else
        echo "$project_name"
    fi
}

# Auto-discover billing export table
discover_billing_table() {
    log "Auto-discovering billing export table..."
    
    # Check for BigQuery access method
    local bq_method=$(check_bigquery_access)
    if [[ -z "$bq_method" ]]; then
        log "❌ No BigQuery access method found"
        log "   Please install one of the following (manually):"
        log "   - bq CLI: gcloud components install bq"
        log "   - Python library: pip install google-cloud-bigquery"
        return 1
    fi
    
    log "Using BigQuery access method: $bq_method"
    
    # Log the authenticated account/service account being used
    if [[ "$bq_method" == "bq" ]]; then
        local bq_account=$(bq show --format=prettyjson 2>/dev/null | jq -r '.configuration.serviceAccount' 2>/dev/null || echo "")
        if [[ -n "$bq_account" && "$bq_account" != "null" ]]; then
            log "BigQuery service account: $bq_account"
        else
            local gcloud_account=$(gcloud config get-value account 2>/dev/null || echo "")
            if [[ -n "$gcloud_account" ]]; then
                log "Authenticated as: $gcloud_account"
            else
                log "Using Application Default Credentials"
            fi
        fi
    else
        # For Python, try to get the account from gcloud
        local gcloud_account=$(gcloud config get-value account 2>/dev/null || echo "")
        if [[ -n "$gcloud_account" ]]; then
            log "Authenticated as: $gcloud_account"
        else
            # Try to get service account from credentials file
            local creds_file="${GOOGLE_APPLICATION_CREDENTIALS:-}"
            if [[ -z "$creds_file" ]]; then
                # Check default ADC location
                creds_file="$HOME/.config/gcloud/application_default_credentials.json"
            fi
            
            if [[ -f "$creds_file" ]]; then
                local sa_email=$(jq -r '.client_email // empty' "$creds_file" 2>/dev/null || echo "")
                if [[ -n "$sa_email" && "$sa_email" != "null" ]]; then
                    log "Using service account from credentials: $sa_email"
                else
                    # Try to get account info from Python BigQuery client
                    local python_cmd=$(check_python_bq_available)
                    if [[ -n "$python_cmd" ]]; then
                        local python_account=$($python_cmd -c "
from google.auth import default
from google.auth.exceptions import DefaultCredentialsError
import json
import sys

try:
    credentials, project = default()
    if hasattr(credentials, 'service_account_email'):
        print(credentials.service_account_email)
    elif hasattr(credentials, 'client_email'):
        print(credentials.client_email)
    else:
        # For user credentials, try to get email
        if hasattr(credentials, 'token_uri'):
            # This is likely a service account
            print('Service Account (email not available)')
        else:
            print('User Account (email not available)')
except Exception as e:
    sys.stderr.write(f'Error: {e}\n')
    sys.exit(1)
" 2>/dev/null)
                        if [[ -n "$python_account" ]]; then
                            log "Authenticated as: $python_account"
                        else
                            log "Using Application Default Credentials (unable to determine account)"
                        fi
                    else
                        log "Using Application Default Credentials"
                    fi
                fi
            else
                # Try to get account info from Python BigQuery client
                local python_cmd=$(check_python_bq_available)
                if [[ -n "$python_cmd" ]]; then
                    local python_account=$($python_cmd -c "
from google.auth import default
import sys

try:
    credentials, project = default()
    if hasattr(credentials, 'service_account_email'):
        print(credentials.service_account_email)
    elif hasattr(credentials, 'client_email'):
        print(credentials.client_email)
    else:
        print('User/Application Default Credentials')
except Exception as e:
    print('Application Default Credentials')
" 2>/dev/null)
                    if [[ -n "$python_account" ]]; then
                        log "Authenticated as: $python_account"
                    else
                        log "Using Application Default Credentials"
                    fi
                else
                    log "Using Application Default Credentials"
                fi
            fi
        fi
    fi
    
    # Get current project
    local current_project=$(gcloud config get-value project 2>/dev/null || echo "")
    log "Current GCP project: ${current_project:-'not set'}"
    
    local billing_table=""
    
    # Helper function to check if a table exists and is accessible
    # Note: bq_method is in parent scope
    check_table_exists() {
        local table_path="$1"
        
        # Parse table path: project.dataset.table
        IFS='.' read -ra PARTS <<< "$table_path"
        local table_project="${PARTS[0]}"
        local table_dataset="${PARTS[1]}"
        local table_name="${PARTS[2]}"
        
        if [[ "$bq_method" == "bq" ]]; then
            # Use bq show to check if table exists and we can access it
            local table_info=$(bq show --format=json "$table_path" 2>/dev/null)
            if [[ $? -eq 0 && -n "$table_info" ]]; then
                # Verify it has billing export structure by checking for key fields
                local has_cost=$(echo "$table_info" | jq -r '.schema.fields[]? | select(.name == "cost") | .name' 2>/dev/null)
                local has_usage_start=$(echo "$table_info" | jq -r '.schema.fields[]? | select(.name == "usage_start_time") | .name' 2>/dev/null)
                if [[ -n "$has_cost" && -n "$has_usage_start" ]]; then
                    return 0
                fi
            fi
        else
            # Use Python to check table
            local python_result=$(python_check_table "$table_project" "$table_dataset" "$table_name" 2>/dev/null)
            if [[ $? -eq 0 && -n "$python_result" ]]; then
                return 0
            fi
        fi
        return 1
    }
    
    # Strategy 1: Check projects from GCP_PROJECT_IDS first (billing often in one of these)
    if [[ -n "$PROJECT_IDS" ]]; then
        log "Strategy 1: Checking projects from GCP_PROJECT_IDS..."
        IFS=',' read -ra PROJ_ARRAY <<< "$PROJECT_IDS"
        for proj_id in "${PROJ_ARRAY[@]}"; do
            proj_id=$(echo "$proj_id" | xargs)  # trim whitespace
            [[ -z "$proj_id" ]] && continue
            
            log "Checking project: $proj_id"
            
            # Get datasets using appropriate method
            local datasets=""
            if [[ "$bq_method" == "bq" ]]; then
                local bq_output=$(bq ls --format=json --project_id="$proj_id" 2>&1)
                local bq_exit=$?
                
                if [[ $bq_exit -ne 0 ]]; then
                    log "   ⚠️  Cannot list datasets in $proj_id (exit code: $bq_exit)"
                    # Log error details for debugging
                    local error_msg=$(echo "$bq_output" | grep -i "error\|denied\|permission" | head -1)
                    if [[ -n "$error_msg" ]]; then
                        log "   Error details: $error_msg"
                    fi
                    continue
                fi
                
                datasets=$(echo "$bq_output" | jq -r '.[].datasetReference.datasetId' 2>/dev/null || echo "")
            else
                # Use Python
                local python_output=$(python_list_datasets "$proj_id")
                local python_exit=$?
                
                if [[ $python_exit -ne 0 ]]; then
                    log "   ⚠️  Cannot list datasets in $proj_id"
                    # Extract error message (Python writes to stderr, but we capture both)
                    local error_msg=$(echo "$python_output" | grep -i "error\|denied\|permission\|not found" | head -1)
                    if [[ -n "$error_msg" ]]; then
                        log "   Error details: $error_msg"
                    else
                        # Show first few lines of output for debugging
                        local error_preview=$(echo "$python_output" | head -2)
                        if [[ -n "$error_preview" ]]; then
                            log "   Error output: $error_preview"
                        fi
                    fi
                    continue
                fi
                
                # Extract JSON from stdout (filter out any error messages)
                datasets=$(echo "$python_output" | grep -v "Error\|Permission\|denied\|not found" | jq -r '.[].datasetId' 2>/dev/null || echo "")
            fi
            local dataset_count=$(echo "$datasets" | grep -v '^$' | wc -l | tr -d ' ')
            
            if [[ -z "$datasets" || "$dataset_count" -eq 0 ]]; then
                log "   No datasets found in project $proj_id"
                continue
            fi
            
            log "   Found $dataset_count dataset(s) in $proj_id"
            
            # Sort datasets to prioritize billing-related names
            local prioritized_datasets=""
            local other_datasets=""
            
            while IFS= read -r dataset; do
                [[ -z "$dataset" ]] && continue
                # Prioritize datasets with billing/cost/export in name, especially "all_cost_exports"
                if [[ "$dataset" =~ (all_cost_exports|billing|cost|export) ]]; then
                    if [[ "$dataset" == "all_cost_exports" ]]; then
                        prioritized_datasets="${prioritized_datasets}${dataset}"$'\n'
                    else
                        prioritized_datasets="${prioritized_datasets}${dataset}"$'\n'
                    fi
                else
                    other_datasets="${other_datasets}${dataset}"$'\n'
                fi
            done <<< "$datasets"
            
            # Check prioritized datasets first
            datasets="${prioritized_datasets}${other_datasets}"
            
            while IFS= read -r dataset; do
                [[ -z "$dataset" ]] && continue
                log "   Checking dataset: $dataset"
                
                # Get tables using appropriate method
                local tables=""
                if [[ "$bq_method" == "bq" ]]; then
                    local table_output=$(bq ls --format=json --project_id="$proj_id" "$dataset" 2>&1)
                    tables=$(echo "$table_output" | jq -r '.[].tableReference.tableId' 2>/dev/null || echo "")
                else
                    # Use Python
                    local table_output=$(python_list_tables "$proj_id" "$dataset")
                    local table_exit=$?
                    
                    if [[ $table_exit -ne 0 ]]; then
                        local error_msg=$(echo "$table_output" | grep -i "error\|denied\|permission\|not found" | head -1)
                        if [[ -n "$error_msg" ]]; then
                            log "     Error listing tables: $error_msg"
                        fi
                    fi
                    
                    tables=$(echo "$table_output" | grep -v "Error\|Permission\|denied" | jq -r '.[].tableId' 2>/dev/null || echo "")
                fi
                local table_count=$(echo "$tables" | grep -v '^$' | wc -l | tr -d ' ')
                
                if [[ -n "$tables" && "$table_count" -gt 0 ]]; then
                    log "     Found $table_count table(s) in dataset $dataset"
                fi
                
                while IFS= read -r table; do
                    [[ -z "$table" ]] && continue
                    
                    if [[ "$table" =~ ^gcp_billing_export_v1_ ]]; then
                        local full_table="${proj_id}.${dataset}.${table}"
                        log "     Found potential billing table: $full_table"
                        
                        if check_table_exists "$full_table"; then
                            billing_table="$full_table"
                            log "✅ Verified billing table: $billing_table"
                            break 3
                        else
                            log "     Table $full_table verification failed"
                        fi
                    fi
                done <<< "$tables"
            done <<< "$datasets"
        done
    fi
    
    # Strategy 2: Try listing datasets without specifying project (uses default)
    if [[ -z "$billing_table" ]]; then
        log "Strategy 2: Checking default BigQuery project..."
        
        local datasets=""
        if [[ "$bq_method" == "bq" ]]; then
            local bq_output=$(bq ls --format=json 2>&1)
            local bq_exit=$?
            
            if [[ $bq_exit -ne 0 ]]; then
                log "   ⚠️  Cannot list datasets in default project (exit code: $bq_exit)"
            else
                datasets=$(echo "$bq_output" | jq -r '.[].datasetReference.datasetId' 2>/dev/null || echo "")
            fi
        else
            # Use Python with no project (uses default)
            local python_output=$(python_list_datasets "" 2>&1)
            local python_exit=$?
            
            if [[ $python_exit -ne 0 ]]; then
                log "   ⚠️  Cannot list datasets in default project"
            else
                datasets=$(echo "$python_output" | jq -r '.[].datasetId' 2>/dev/null || echo "")
            fi
        fi
        
        if [[ -n "$datasets" ]]; then
            local dataset_count=$(echo "$datasets" | grep -v '^$' | wc -l | tr -d ' ')
            
            if [[ -n "$datasets" && "$dataset_count" -gt 0 ]]; then
                log "   Found $dataset_count dataset(s) in default project"
                
                while IFS= read -r dataset; do
                    [[ -z "$dataset" ]] && continue
                    log "   Checking dataset: $dataset"
                    
                    # Get tables using appropriate method
                    local tables=""
                    if [[ "$bq_method" == "bq" ]]; then
                        local table_output=$(bq ls --format=json "$dataset" 2>&1)
                        tables=$(echo "$table_output" | jq -r '.[].tableReference.tableId' 2>/dev/null || echo "")
                    else
                        # Use Python - need to get project first
                        local table_project=$(gcloud config get-value project 2>/dev/null || echo "")
                        if [[ -z "$table_project" ]]; then
                            # Try to get from table metadata if we can
                            table_project=""
                        fi
                        if [[ -n "$table_project" ]]; then
                            local table_output=$(python_list_tables "$table_project" "$dataset")
                            local table_exit=$?
                            
                            if [[ $table_exit -ne 0 ]]; then
                                local error_msg=$(echo "$table_output" | grep -i "error\|denied\|permission\|not found" | head -1)
                                if [[ -n "$error_msg" ]]; then
                                    log "     Error listing tables: $error_msg"
                                fi
                            fi
                            
                            tables=$(echo "$table_output" | grep -v "Error\|Permission\|denied" | jq -r '.[].tableId' 2>/dev/null || echo "")
                        fi
                    fi
                    
                    while IFS= read -r table; do
                        [[ -z "$table" ]] && continue
                        
                        if [[ "$table" =~ ^gcp_billing_export_v1_ ]]; then
                            # Try to get project from table metadata
                            local table_project=""
                            if [[ "$bq_method" == "bq" ]]; then
                                table_project=$(bq show --format=json "$dataset.$table" 2>/dev/null | jq -r '.tableReference.projectId' 2>/dev/null || echo "")
                            else
                                # For Python, try to get from current project or use default
                                table_project=$(gcloud config get-value project 2>/dev/null || echo "")
                            fi
                            
                            if [[ -z "$table_project" && -n "$current_project" ]]; then
                                table_project="$current_project"
                            fi
                            
                            local full_table="${table_project:+${table_project}.}${dataset}.${table}"
                            if [[ -z "$table_project" ]]; then
                                full_table="${dataset}.${table}"
                            fi
                            
                            log "     Found potential billing table: $full_table"
                            
                            if check_table_exists "$full_table"; then
                                billing_table="$full_table"
                                log "✅ Verified billing table: $billing_table"
                                break 2
                            else
                                log "     Table $full_table verification failed"
                            fi
                        fi
                    done <<< "$tables"
                done <<< "$datasets"
            else
                log "   No datasets found in default project"
            fi
        fi
    fi
    
    # Strategy 3: Try with explicit current project
    if [[ -z "$billing_table" && -n "$current_project" ]]; then
        log "Strategy 3: Checking current project: $current_project"
        
        local datasets=""
        if [[ "$bq_method" == "bq" ]]; then
            datasets=$(bq ls --format=json --project_id="$current_project" 2>/dev/null | jq -r '.[].datasetReference.datasetId' 2>/dev/null || echo "")
        else
            local python_output=$(python_list_datasets "$current_project" 2>&1)
            datasets=$(echo "$python_output" | jq -r '.[].datasetId' 2>/dev/null || echo "")
        fi
        
        while IFS= read -r dataset; do
            [[ -z "$dataset" ]] && continue
            
            local tables=""
            if [[ "$bq_method" == "bq" ]]; then
                tables=$(bq ls --format=json --project_id="$current_project" "$dataset" 2>/dev/null | jq -r '.[].tableReference.tableId' 2>/dev/null || echo "")
            else
                local table_output=$(python_list_tables "$current_project" "$dataset")
                local table_exit=$?
                
                if [[ $table_exit -ne 0 ]]; then
                    local error_msg=$(echo "$table_output" | grep -i "error\|denied\|permission\|not found" | head -1)
                    if [[ -n "$error_msg" ]]; then
                        log "   Error listing tables: $error_msg"
                    fi
                fi
                
                tables=$(echo "$table_output" | grep -v "Error\|Permission\|denied" | jq -r '.[].tableId' 2>/dev/null || echo "")
            fi
            
            while IFS= read -r table; do
                [[ -z "$table" ]] && continue
                
                if [[ "$table" =~ ^gcp_billing_export_v1_ ]]; then
                    local full_table="${current_project}.${dataset}.${table}"
                    log "Found potential billing table: $full_table"
                    
                    if check_table_exists "$full_table"; then
                        billing_table="$full_table"
                        log "✅ Verified billing table: $billing_table"
                        break 2
                    fi
                fi
            done <<< "$tables"
        done <<< "$datasets"
    fi
    
    # Strategy 4: Search across accessible projects (limited search)
    if [[ -z "$billing_table" ]]; then
        log "Strategy 4: Searching across accessible projects (limited to 5 projects)..."
        local projects=$(gcloud projects list --format="value(projectId)" 2>/dev/null | head -5)
        local project_count=$(echo "$projects" | grep -v '^$' | wc -l | tr -d ' ')
        log "   Found $project_count accessible project(s)"
        
        while IFS= read -r proj; do
            [[ -z "$proj" ]] && continue
            [[ "$proj" == "$current_project" ]] && continue  # Skip if already checked
            
            # Skip projects already checked in Strategy 1
            local skip=false
            if [[ -n "$PROJECT_IDS" ]]; then
                IFS=',' read -ra PROJ_ARRAY <<< "$PROJECT_IDS"
                for checked_proj in "${PROJ_ARRAY[@]}"; do
                    if [[ "$proj" == "$(echo "$checked_proj" | xargs)" ]]; then
                        skip=true
                        break
                    fi
                done
            fi
            [[ "$skip" == true ]] && continue
            
            log "   Checking project: $proj"
            
            local datasets=""
            if [[ "$bq_method" == "bq" ]]; then
                local bq_output=$(bq ls --format=json --project_id="$proj" 2>&1)
                local bq_exit=$?
                
                if [[ $bq_exit -ne 0 ]]; then
                    log "     ⚠️  Cannot list datasets in $proj"
                    continue
                fi
                
                datasets=$(echo "$bq_output" | jq -r '.[].datasetReference.datasetId' 2>/dev/null || echo "")
            else
                local python_output=$(python_list_datasets "$proj" 2>&1)
                local python_exit=$?
                
                if [[ $python_exit -ne 0 ]]; then
                    log "     ⚠️  Cannot list datasets in $proj"
                    continue
                fi
                
                datasets=$(echo "$python_output" | jq -r '.[].datasetId' 2>/dev/null || echo "")
            fi
            
            while IFS= read -r dataset; do
                [[ -z "$dataset" ]] && continue
                
                # Look for billing-related dataset names as a hint
                if [[ "$dataset" =~ (billing|cost|export) ]]; then
                    log "     Found billing-related dataset: $dataset"
                fi
                
                local tables=""
                if [[ "$bq_method" == "bq" ]]; then
                    local table_output=$(bq ls --format=json --project_id="$proj" "$dataset" 2>&1)
                    tables=$(echo "$table_output" | jq -r '.[].tableReference.tableId' 2>/dev/null || echo "")
                else
                    local table_output=$(python_list_tables "$proj" "$dataset")
                    local table_exit=$?
                    
                    if [[ $table_exit -ne 0 ]]; then
                        local error_msg=$(echo "$table_output" | grep -i "error\|denied\|permission\|not found" | head -1)
                        if [[ -n "$error_msg" ]]; then
                            log "     Error listing tables: $error_msg"
                        fi
                    fi
                    
                    tables=$(echo "$table_output" | grep -v "Error\|Permission\|denied" | jq -r '.[].tableId' 2>/dev/null || echo "")
                fi
                
                while IFS= read -r table; do
                    [[ -z "$table" ]] && continue
                    
                    if [[ "$table" =~ ^gcp_billing_export_v1_ ]]; then
                        local full_table="${proj}.${dataset}.${table}"
                        log "     Found potential billing table: $full_table"
                        
                        if check_table_exists "$full_table"; then
                            billing_table="$full_table"
                            log "✅ Verified billing table: $billing_table"
                            break 3
                        else
                            log "     Table $full_table verification failed"
                        fi
                    fi
                done <<< "$tables"
            done <<< "$datasets"
        done <<< "$projects"
    fi
    
    if [[ -n "$billing_table" ]]; then
        echo "$billing_table"
        return 0
    else
        log "❌ Could not auto-discover billing export table"
        log "   Searched: projects from GCP_PROJECT_IDS, default project, current project ($current_project), and accessible projects"
        log "   Tip: Set GCP_BILLING_EXPORT_TABLE manually or ensure billing export is enabled"
        return 1
    fi
}

# Get all unique projects from billing export table
get_all_projects_from_billing() {
    local billing_table="$1"
    local start_date="$2"
    local end_date="$3"
    
    log "Querying billing table for all projects with costs in date range..."
    
    # Extract project ID from billing table (format: project-id.dataset.table)
    local billing_project=$(echo "$billing_table" | cut -d'.' -f1)
    
    local query="
    SELECT DISTINCT 
        project.id as project_id,
        project.name as project_name
    FROM \`${billing_table}\`
    WHERE DATE(usage_start_time) >= '${start_date}'
      AND DATE(usage_start_time) <= '${end_date}'
      AND cost > 0
    ORDER BY project_id
    "
    
    local query_result=""
    if check_bq_available; then
        query_result=$(bq query --project_id="$billing_project" --use_legacy_sql=false --format=json --max_rows=10000 "$query" 2>&1)
        local query_exit=$?
        
        if [[ $query_exit -ne 0 ]]; then
            log "❌ Failed to query all projects from billing table"
            log "Query error: $(echo "$query_result" | head -5)"
            log "Billing table: $billing_table"
            log "Billing project: $billing_project"
            return 1
        fi
        
        # Extract project IDs from JSON result
        # Filter out BigQuery status messages (but keep the JSON array)
        local json_result=$(echo "$query_result" | grep -v "^Waiting\|^Job" | grep -E '^\[' | head -1)
        
        if [[ -z "$json_result" ]]; then
            log "⚠️  No JSON result from query"
            log "Query output: $(echo "$query_result" | head -10)"
            return 1
        fi
        
        local projects=$(echo "$json_result" | jq -r '.[] | .project_id' 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//')
        
        if [[ -z "$projects" ]]; then
            log "⚠️  No projects found with costs in date range $start_date to $end_date"
            log "JSON result: $(echo "$json_result" | head -10)"
            return 1
        fi
        
        log "✅ Found projects in billing export: $projects"
        echo "$projects"
    else
        local python_cmd=$(check_python_bq_available)
        if [[ -n "$python_cmd" ]]; then
            query_result=$($python_cmd -c "
from google.cloud import bigquery
import json
import sys

try:
    client = bigquery.Client()
    query_job = client.query('''${query}''')
    result = list(query_job.result(max_results=10000))
    projects = sorted(set([row.project_id for row in result if row.project_id and row.project_id.strip()]))
    if projects:
        print(','.join(projects))
    else:
        sys.stderr.write('No projects found in billing export\n')
        sys.exit(1)
except Exception as e:
    sys.stderr.write(f'Error: {e}\n')
    sys.exit(1)
" 2>&1)
            
            local python_exit=$?
            if [[ $python_exit -eq 0 && -n "$query_result" ]]; then
                echo "$query_result"
            else
                log "❌ Failed to query all projects from billing table"
                if [[ -n "$query_result" ]]; then
                    log "Query output: $query_result"
                fi
                return 1
            fi
        else
            log "❌ No BigQuery access method available"
            return 1
        fi
    fi
}

# Query GCP BigQuery for cost data
get_cost_data() {
    local project_id="$1"
    local start_date="$2"
    local end_date="$3"
    local billing_table="$4"
    
    # Extract project ID from billing table (format: project-id.dataset.table)
    local billing_project=$(echo "$billing_table" | cut -d'.' -f1)
    
    log "Querying BigQuery for costs from $start_date to $end_date for project: $project_id"
    log "Using billing table: $billing_table"
    
    # First, try a simple query to check if there's ANY data in the table
    local test_query="SELECT COUNT(*) as total_rows FROM \`${billing_table}\` WHERE DATE(usage_start_time) >= '${start_date}' AND DATE(usage_start_time) <= '${end_date}' LIMIT 1"
    
    local test_result=""
    if check_bq_available; then
        test_result=$(bq query --project_id="$billing_project" --use_legacy_sql=false --format=json --max_rows=1 "$test_query" 2>&1)
    else
        local python_cmd=$(check_python_bq_available)
        if [[ -n "$python_cmd" ]]; then
            test_result=$($python_cmd -c "
from google.cloud import bigquery
import json
import sys

try:
    client = bigquery.Client()
    query_job = client.query('''${test_query}''')
    result = list(query_job.result(max_results=1))
    if result:
        print(json.dumps([{'total_rows': result[0].total_rows}]))
    else:
        print('[]')
except Exception as e:
    sys.stderr.write(f'Error: {e}\n')
    sys.exit(1)
" 2>&1)
        fi
    fi
    
    local total_rows=$(echo "$test_result" | grep -v "Error\|Permission" | jq -r '.[0].total_rows // 0' 2>/dev/null || echo "0")
    log "Total rows in billing table for date range: $total_rows"
    
    # Query to get costs aggregated by project, service, and SKU
    # Try multiple project ID formats since billing export might use different formats
    local query="
    SELECT 
        project.name as project_name,
        project.id as project_id,
        service.description as service_name,
        sku.description as sku_description,
        SUM(cost) as total_cost
    FROM \`${billing_table}\`
    WHERE DATE(usage_start_time) >= '${start_date}'
      AND DATE(usage_start_time) <= '${end_date}'
      AND (project.id = '${project_id}' OR project.name = '${project_id}')
    GROUP BY project_name, project_id, service_name, sku_description
    HAVING total_cost > 0
    ORDER BY total_cost DESC
    "
    
    log "Executing cost query for project: $project_id"
    
    # Try bq CLI first, then Python as fallback
    local query_result=""
    local query_error=""
    
    if check_bq_available; then
        query_result=$(bq query --project_id="$billing_project" --use_legacy_sql=false --format=json --max_rows=10000 "$query" 2>&1)
        local query_exit=$?
        
        if [[ $query_exit -ne 0 ]]; then
            query_error=$(echo "$query_result" | grep -i "error\|denied\|permission" | head -1)
            if [[ -n "$query_error" ]]; then
                log "❌ Query error: $query_error"
            else
                log "❌ Query failed (exit code: $query_exit)"
                log "Query output: $(echo "$query_result" | head -5)"
            fi
            echo '[]'
            return 1
        fi
        
        # Filter out error messages and return JSON
        echo "$query_result" | grep -v "Error\|Permission\|denied" | jq -r '.' 2>/dev/null || echo '[]'
    else
        local python_cmd=$(check_python_bq_available)
        if [[ -n "$python_cmd" ]]; then
            # Use Python BigQuery client
            query_result=$($python_cmd -c "
from google.cloud import bigquery
from google.api_core import exceptions
import json
import sys

try:
    client = bigquery.Client()
    query_job = client.query('''${query}''')
    results = query_job.result(max_results=10000)
    rows = []
    for row in results:
        rows.append({
            'project_name': row.project_name,
            'project_id': row.project_id,
            'service_name': row.service_name,
            'sku_description': row.sku_description,
            'total_cost': float(row.total_cost)
        })
    print(json.dumps(rows))
except exceptions.Forbidden as e:
    sys.stderr.write(f'Permission denied: {e}\n')
    sys.exit(1)
except Exception as e:
    sys.stderr.write(f'Error: {e}\n')
    sys.exit(1)
" 2>&1)
            local python_exit=$?
            
            if [[ $python_exit -ne 0 ]]; then
                query_error=$(echo "$query_result" | grep -i "error\|denied\|permission" | head -1)
                if [[ -n "$query_error" ]]; then
                    log "❌ Query error: $query_error"
                else
                    log "❌ Query failed"
                    log "Query output: $(echo "$query_result" | head -5)"
                fi
                echo '[]'
                return 1
            fi
            
            # Show errors instead of hiding them
            if echo "$query_result" | grep -qi "error"; then
                log "❌ Time-series Python query error: $(echo "$query_result" | head -5)"
                echo '[]'
            else
                echo "$query_result" | jq -r '.' 2>/dev/null || echo '[]'
            fi
        else
            log "❌ No BigQuery access method available for querying"
            echo '[]'
            return 1
        fi
    fi
}

# Parse and aggregate cost data
parse_cost_data() {
    local cost_data="$1"
    
    # Aggregate by project and service
    # Note: BigQuery returns numbers as strings (including scientific notation like "1.2E-4")
    # so we need to convert them with tonumber before doing math operations
    echo "$cost_data" | jq -r '
        group_by(.project_name) |
        map({
            projectName: .[0].project_name,
            totalCost: (map(.total_cost | tonumber) | add),
            services: (
                group_by(.service_name) |
                map({
                    serviceName: .[0].service_name,
                    cost: (map(.total_cost | tonumber) | add),
                    skus: map({
                        skuDescription: .sku_description,
                        cost: (.total_cost | tonumber)
                    }) | sort_by(-.cost)
                }) |
                sort_by(-.cost)
            )
        }) |
        sort_by(-.totalCost)
    '
}

# Generate table report
generate_table_report() {
    local aggregated_data="$1"
    local start_date="$2"
    local end_date="$3"
    local total_cost="$4"
    
    # Calculate summary statistics
    local project_count=$(echo "$aggregated_data" | jq 'length')
    local high_cost_projects=$(echo "$aggregated_data" | jq --argjson total "$total_cost" '[.[] | select((.totalCost / $total * 100) > 20)] | length')
    local significant_contributors=$(echo "$aggregated_data" | jq --argjson total "$total_cost" '[.[] | select((.totalCost / $total * 100) > 1)] | length')
    local projects_under_1=$(echo "$aggregated_data" | jq '[.[] | select(.totalCost < 1)] | length')
    local unique_projects=$(echo "$aggregated_data" | jq -r '[.[].projectName // "unknown"] | unique | length')
    
    # Calculate top quartile projects (top 25% by cost) - these are cost outliers worth investigating
    local sorted_data=$(echo "$aggregated_data" | jq 'sort_by(-.totalCost)')
    local top_quartile_count=$(echo "$project_count" | awk '{printf "%.0f", ($1 * 0.25) + 0.5}')
    [[ "$top_quartile_count" -lt 1 ]] && top_quartile_count=1
    local cost_outliers=$top_quartile_count
    
    # Get project breakdown
    local project_breakdown=$(echo "$aggregated_data" | jq -r '
        map({
            project: .projectName,
            cost: .totalCost
        }) |
        sort_by(-.cost) |
        map(
            "   • " + 
            .project + 
            ": $" + 
            ((.cost * 100 | round) / 100 | tostring)
        ) |
        join("\n")
    ')
    
    cat > "$REPORT_FILE" << EOF
╔══════════════════════════════════════════════════════════════════════╗
║          GCP COST REPORT - LAST 30 DAYS                             ║
║          Period: $start_date to $end_date                      ║
╚══════════════════════════════════════════════════════════════════════╝

📊 COST SUMMARY
$(printf '═%.0s' {1..72})

   💰 Total Cost Across All Projects:    \$$total_cost
   🔐 Projects Analyzed:                  $unique_projects
   ⚠️  High Cost Contributors (>20%):     $high_cost_projects
   📊 Significant Contributors (>1%):     $significant_contributors
   🔍 Top Cost Projects (Top 25%):        $cost_outliers
   💤 Projects Under \$1:                  $projects_under_1

$(printf '─%.0s' {1..72})

💳 COST BY PROJECT:
$project_breakdown

$(printf '═%.0s' {1..72})

📋 TOP 10 PROJECTS BY COST
$(printf '═%.0s' {1..72})

   PROJECT                              COST          %
$(printf '─%.0s' {1..72})

EOF

    # Generate top 10 projects summary table
    echo "$aggregated_data" | jq -r --argjson total "$total_cost" '
        .[:10] |
        to_entries |
        map(
            ((.key + 1) | tostring | if length == 1 then " " + . else . end) + 
            ". " + 
            (.value.projectName | 
                if length > 40 then .[:37] + "..." else . + (" " * (40 - length)) end
            ) + 
            "  $" + 
            ((.value.totalCost | . * 100 | round / 100 | tostring) as $cost |
             if ($cost | contains(".")) then
                 ($cost | split(".") | 
                  if (.[1] | length) == 1 then .[0] + "." + .[1] + "0"
                  else $cost end)
             else
                 $cost + ".00"
             end |
             if length < 9 then (" " * (9 - length)) + . else . end
            ) + 
            "  (" + 
            ((.value.totalCost / $total * 100) | floor | tostring | 
                if length == 1 then " " + . else . end
            ) + 
            "%)"
        ) |
        join("\n")
    ' >> "$REPORT_FILE"

    cat >> "$REPORT_FILE" << EOF

$(printf '═%.0s' {1..72})

🔍 DETAILED BREAKDOWN BY PROJECT
$(printf '═%.0s' {1..72})

EOF
    
    # Generate report by project
    echo "$aggregated_data" | jq -r --arg sep "$(printf '─%.0s' {1..72})" '
        .[] | 
        "
🔹 PROJECT: " + .projectName + "
   Total Cost: $" + ((.totalCost * 100 | round) / 100 | tostring) + " (" + ((.totalCost / '$total_cost' * 100) | floor | tostring) + "% of total)
   " + (if (.totalCost / '$total_cost' * 100) > 20 then "⚠️  HIGH COST CONTRIBUTOR" else "" end) + "
   
   Top Services:
" + (
    .services[:10] | 
    map("      • " + .serviceName + ": $" + ((.cost * 100 | round) / 100 | tostring)) | 
    join("\n")
) + "
   " + (if (.services | length) > 10 then "... and " + ((.services | length) - 10 | tostring) + " more services" else "" end) + "
" + $sep
    ' >> "$REPORT_FILE"
    
    # Generate top 10 services overall
    cat >> "$REPORT_FILE" << EOF

╔══════════════════════════════════════════════════════════════════════╗
║          TOP 10 MOST EXPENSIVE SERVICES                              ║
╚══════════════════════════════════════════════════════════════════════╝

EOF
    
    echo "$aggregated_data" | jq -r '
        [.[] | .projectName as $project | .services[] | . + {projectName: $project}] |
        sort_by(-.cost) |
        .[:10] |
        to_entries |
        map(((.key + 1) | tostring) + ". " + .value.serviceName + " (" + .value.projectName + ") - $" + ((.value.cost * 100 | round) / 100 | tostring)) |
        join("\n")
    ' >> "$REPORT_FILE"
    
    cat >> "$REPORT_FILE" << EOF

$(printf '═%.0s' {1..72})

📈 COST OPTIMIZATION TIPS:
   • Review high-cost projects for optimization opportunities
   • Check for unused or underutilized resources
   • Consider committed use discounts for predictable workloads
   • Enable cost anomaly detection and budgets
   • Review storage classes and lifecycle policies
   • Use preemptible VMs for fault-tolerant workloads

EOF
}

# Generate time-series section for report
generate_timeseries_section() {
    local timeseries_data="$1"
    local date_ranges="$2"
    local report_file="${3:-$REPORT_FILE}"
    
    # Check if we have time-series data
    if [[ -z "$timeseries_data" || "$timeseries_data" == "[]" ]]; then
        log "No time-series data to display"
        return 0
    fi
    
    # Aggregate by project
    local project_aggregates=$(echo "$timeseries_data" | jq '
        group_by(.projectId) | 
        map({
            projectId: .[0].projectId,
            projectName: .[0].projectName,
            totalCost: (map(.totalCost) | add),
            daily: ([.[].daily] | transpose | map({
                date: .[0].date,
                cost: (map(.cost) | add)
            })),
            weekly: {cost: (map(.weekly.cost) | add)},
            monthly: {cost: (map(.monthly.cost) | add)},
            lookback: {cost: (map(.lookback.cost) | add)}
        }) |
        sort_by(-.totalCost)
    ')
    
    cat >> "$report_file" << EOF

╔══════════════════════════════════════════════════════════════════════╗
║          SPENDING TRENDS & TIME-SERIES ANALYSIS                      ║
╚══════════════════════════════════════════════════════════════════════╝

EOF
    
    # Display time-series for top 5 projects
    echo "$project_aggregates" | jq -r --arg days "$LOOKBACK_DAYS" '
        .[:5] |
        to_entries |
        map("
🔹 PROJECT: " + .value.projectName + "
   
   📅 DAILY SPEND (Last 7 Days):
" + (
    .value.daily | 
    reverse |
    map("      " + .date + ":  $" + ((.cost * 100 | round) / 100 | tostring)) | 
    join("\n")
) + "
   
   📊 AGGREGATED SPEND:
      Last 7 Days:   $" + ((.value.weekly.cost * 100 | round) / 100 | tostring) + "
      Last 30 Days:  $" + ((.value.monthly.cost * 100 | round) / 100 | tostring) + "
      Last " + $days + " Days:  $" + ((.value.lookback.cost * 100 | round) / 100 | tostring) + "
────────────────────────────────────────────────────────────────────────
") |
        join("\n")
    ' >> "$report_file"
    
    log "Time-series section added to report"
}

# Generate CSV report
generate_csv_report() {
    local aggregated_data="$1"
    
    echo "ProjectName,ServiceName,SkuDescription,Cost" > "$CSV_FILE"
    
    echo "$aggregated_data" | jq -r '
        .[] |
        .projectName as $project |
        .services[] |
        .serviceName as $service |
        .skus[] |
        [$project, $service, .skuDescription, (.cost | tostring)] |
        @csv
    ' >> "$CSV_FILE"
    
    log "CSV report saved to: $CSV_FILE"
}

# Generate JSON report
generate_json_report() {
    local aggregated_data="$1"
    local start_date="$2"
    local end_date="$3"
    local total_cost="$4"
    
    jq -n \
        --arg startDate "$start_date" \
        --arg endDate "$end_date" \
        --arg totalCost "$total_cost" \
        --argjson data "$aggregated_data" \
        '{
            reportPeriod: {
                startDate: $startDate,
                endDate: $endDate
            },
            totalCost: ($totalCost | tonumber),
            currency: "USD",
            projects: $data
        }' > "$JSON_FILE"
    
    log "JSON report saved to: $JSON_FILE"
}

# Process a single project
process_project() {
    local project_id="$1"
    local start_date="$2"
    local end_date="$3"
    local billing_table="$4"
    
    log "Processing project: $project_id"
    
    # Get project name
    local project_name=$(get_project_name "$project_id")
    
    # Get cost data from BigQuery
    local cost_data=$(get_cost_data "$project_id" "$start_date" "$end_date" "$billing_table")
    
    # Check if we got valid data
    local row_count=$(echo "$cost_data" | jq 'length' 2>/dev/null || echo "0")
    if [[ $row_count -eq 0 ]]; then
        log "⚠️  Project $project_id: No cost data returned"
        log "   This could mean:"
        log "   - No costs incurred for this project in the date range"
        log "   - Project ID doesn't match billing export format"
        log "   - Query returned empty results (check table and date range)"
        
        # Try a broader query to see if there's ANY data for this project
        log "   Checking if project exists in billing data..."
        local project_check_query="SELECT DISTINCT project.id, project.name FROM \`${billing_table}\` WHERE DATE(usage_start_time) >= '${start_date}' AND DATE(usage_start_time) <= '${end_date}' LIMIT 100"
        
        local project_check=""
        if check_bq_available; then
            project_check=$(bq query --project_id="$billing_project" --use_legacy_sql=false --format=json --max_rows=100 "$project_check_query" 2>&1 | grep -v "Error\|Permission" | jq -r '.[] | "\(.id) (\(.name))"' 2>/dev/null | head -10)
        else
            local python_cmd=$(check_python_bq_available)
            if [[ -n "$python_cmd" ]]; then
                project_check=$($python_cmd -c "
from google.cloud import bigquery
import json
import sys

try:
    client = bigquery.Client()
    query_job = client.query('''${project_check_query}''')
    results = query_job.result(max_results=100)
    projects = []
    for row in results:
        projects.append(f\"{row.id} ({row.name})\")
    print('\n'.join(projects[:10]))
except Exception as e:
    sys.stderr.write(f'Error: {e}\n')
    sys.exit(1)
" 2>&1 | grep -v "Error\|Permission" | head -10)
            fi
        fi
        
        if [[ -n "$project_check" ]]; then
            log "   Projects found in billing data:"
            echo "$project_check" | while IFS= read -r proj_info; do
                log "     - $proj_info"
            done
        else
            log "   Could not retrieve project list from billing data"
        fi
        
        return 1
    fi
    
    log "✅ Project $project_id ($project_name): Retrieved $row_count cost records"
    
    # Parse and aggregate data
    local aggregated_data=$(parse_cost_data "$cost_data")
    
    # Add project ID to each entry
    aggregated_data=$(echo "$aggregated_data" | jq --arg proj "$project_id" --arg projName "$project_name" 'map(. + {projectId: $proj, projectName: $projName})')
    
    echo "$aggregated_data"
}

# Get time-series cost data for a project
get_timeseries_cost_data() {
    local billing_table="$1"
    local start_date="$2"
    local end_date="$3"
    local project_filter="$4"
    
    local billing_project=$(echo "$billing_table" | cut -d'.' -f1)
    
    local query="
    SELECT 
        DATE(usage_start_time) as usage_date,
        project.id as project_id,
        project.name as project_name,
        service.description as service_name,
        SUM(cost) as total_cost
    FROM \`${billing_table}\`
    WHERE DATE(usage_start_time) >= '${start_date}'
      AND DATE(usage_start_time) <= '${end_date}'
      ${project_filter}
    GROUP BY usage_date, project_id, project_name, service_name
    HAVING total_cost > 0
    ORDER BY usage_date DESC, total_cost DESC
    "
    
    log "Querying time-series cost data from $start_date to $end_date"
    
    local query_result=""
    if check_bq_available; then
        query_result=$(bq query --project_id="$billing_project" --use_legacy_sql=false --format=json --max_rows=100000 "$query" 2>&1)
        local query_exit=$?
        
        if [[ $query_exit -ne 0 ]]; then
            log "❌ Time-series query failed (exit code: $query_exit)"
            echo '[]'
            return 1
        fi
        
        # Don't hide errors!
        local json_result=$(echo "$query_result" | grep -E '^\[' | head -1)
        if [[ -z "$json_result" ]]; then
            log "❌ Time-series query returned no valid JSON"
            log "Query output: $(echo "$query_result" | head -10)"
            echo '[]'
        else
            echo "$json_result"
        fi
    else
        local python_cmd=$(check_python_bq_available)
        if [[ -n "$python_cmd" ]]; then
            query_result=$($python_cmd -c "
from google.cloud import bigquery
import json
import sys

try:
    client = bigquery.Client()
    query_job = client.query('''${query}''')
    results = query_job.result(max_results=100000)
    rows = []
    for row in results:
        rows.append({
            'usage_date': str(row.usage_date),
            'project_id': row.project_id,
            'project_name': row.project_name,
            'service_name': row.service_name,
            'total_cost': float(row.total_cost)
        })
    print(json.dumps(rows))
except Exception as e:
    sys.stderr.write(f'Error: {e}\n')
    sys.exit(1)
" 2>&1)
            local python_exit=$?
            
            if [[ $python_exit -ne 0 ]]; then
                log "❌ Time-series query failed"
                echo '[]'
                return 1
            fi
            
            # Show errors instead of hiding them
            if echo "$query_result" | grep -qi "error"; then
                log "❌ Time-series Python query error: $(echo "$query_result" | head -5)"
                echo '[]'
            else
                echo "$query_result" | jq -r '.' 2>/dev/null || echo '[]'
            fi
        else
            log "❌ No BigQuery access method available"
            echo '[]'
            return 1
        fi
    fi
}

# Aggregate time-series data into daily/weekly/monthly/quarterly
aggregate_timeseries_costs() {
    local cost_data="$1"
    local date_ranges="$2"
    
    echo "$cost_data" | jq \
        --argjson ranges "$date_ranges" \
        '
        # Group by project and service
        group_by(.project_id + "_" + .service_name) |
        map(. as $records | {
            projectId: $records[0].project_id,
            projectName: $records[0].project_name,
            serviceName: $records[0].service_name,
            totalCost: ($records | map(.total_cost | tonumber) | add),
            daily: ($ranges.daily | map(. as $date | {
                date: $date,
                cost: ([$records[] | select(.usage_date == $date) | .total_cost | tonumber] | add // 0)
            })),
            weekly: {
                startDate: $ranges.weekly.start,
                endDate: $ranges.weekly.end,
                cost: ($records | map(select(.usage_date >= $ranges.weekly.start and .usage_date <= $ranges.weekly.end) | .total_cost | tonumber) | add // 0)
            },
            monthly: {
                startDate: $ranges.monthly.start,
                endDate: $ranges.monthly.end,
                cost: ($records | map(select(.usage_date >= $ranges.monthly.start and .usage_date <= $ranges.monthly.end) | .total_cost | tonumber) | add // 0)
            },
            lookback: {
                startDate: $ranges.lookback.start,
                endDate: $ranges.lookback.end,
                cost: ($records | map(select(.usage_date >= $ranges.lookback.start and .usage_date <= $ranges.lookback.end) | .total_cost | tonumber) | add // 0)
            }
        }) |
        sort_by(-.totalCost)
        '
}

# Detect cost anomalies in time-series data
detect_timeseries_anomalies() {
    local timeseries_data="$1"
    local threshold_multiplier="${2:-2.0}"
    
    local issues='[]'
    
    # Aggregate by project for daily anomaly detection
    local aggregated_projects=$(echo "$timeseries_data" | jq -c \
        'group_by(.projectId) | 
         map({
             projectId: .[0].projectId,
             projectName: .[0].projectName,
             totalCost: (map(.totalCost) | add),
             services: .,
             daily: ([.[].daily] | transpose | map({
                 date: .[0].date,
                 cost: (map(.cost) | add)
             })),
             weekly: {cost: (map(.weekly.cost) | add)},
             monthly: {cost: (map(.monthly.cost) | add)},
             lookback: {cost: (map(.lookback.cost) | add)}
         })')
    
    # Process each project (avoiding pipe into while loop to prevent subshell issues)
    local project_count=$(echo "$aggregated_projects" | jq 'length')
    for ((i=0; i<project_count; i++)); do
        local project_data=$(echo "$aggregated_projects" | jq -c ".[$i]")
        
        local project_id=$(echo "$project_data" | jq -r '.projectId')
        local project_name=$(echo "$project_data" | jq -r '.projectName')
        
        # Calculate average daily cost (excluding zeros)
        local daily_costs=$(echo "$project_data" | jq -r '.daily[].cost')
        local avg_daily=$(echo "$daily_costs" | awk 'BEGIN{sum=0; count=0} $1>0{sum+=$1; count++} END{if(count>0) printf "%.2f", sum/count; else print 0}')
        
        # Check each day for spikes
        local daily_count=$(echo "$project_data" | jq '.daily | length')
        for ((j=0; j<daily_count; j++)); do
            local day=$(echo "$project_data" | jq -c ".daily[$j]")
            local date=$(echo "$day" | jq -r '.date')
            local cost=$(echo "$day" | jq -r '.cost')
            
            # Skip if no cost or average is zero
            if (( $(echo "$cost > 0" | bc -l 2>/dev/null || echo 0) )) && (( $(echo "$avg_daily > 0.01" | bc -l 2>/dev/null || echo 0) )); then
                local multiplier=$(echo "scale=2; $cost / $avg_daily" | bc -l 2>/dev/null || echo "1")
                
                # Alert if cost is 2x or more than average
                if (( $(echo "$multiplier >= $threshold_multiplier" | bc -l 2>/dev/null || echo 0) )); then
                    local issue=$(jq -n \
                        --arg title "Cost Spike Detected: $project_name" \
                        --argjson severity 2 \
                        --arg project_id "$project_id" \
                        --arg project_name "$project_name" \
                        --arg date "$date" \
                        --arg cost "$cost" \
                        --arg avg "$avg_daily" \
                        --arg multiplier "$multiplier" \
                        '{
                            title: $title,
                            severity: $severity,
                            expected: ("Daily cost for project \($project_name) should be around $\($avg) (7-day average)"),
                            actual: ("Cost on \($date) was $\($cost), which is \($multiplier)x the average"),
                            details: ("Project: \($project_name) (\($project_id))\nDate: \($date)\nCost: $\($cost)\n7-day average: $\($avg)\nMultiplier: \($multiplier)x"),
                            reproduce_hint: "Review cost breakdown for \($project_name) on \($date) in BigQuery billing export",
                            next_steps: "1. Investigate services and resources used on \($date)\n2. Check for unusual activity or batch jobs\n3. Review application logs and resource usage\n4. Consider implementing budget alerts"
                        }')
                    
                    issues=$(echo "$issues" | jq --argjson issue "$issue" '. + [$issue]')
                    log "⚠️  Cost spike detected for $project_name on $date: \$$cost (${multiplier}x average)"
                fi
            fi
        done
        
        # Check for weekly vs monthly anomalies (50% increase)
        local weekly_cost=$(echo "$project_data" | jq -r '.weekly.cost')
        local monthly_cost=$(echo "$project_data" | jq -r '.monthly.cost')
        
        if (( $(echo "$monthly_cost > 0" | bc -l 2>/dev/null || echo 0) )) && (( $(echo "$weekly_cost > 0" | bc -l 2>/dev/null || echo 0) )); then
            # Expected weekly cost should be ~1/4 of monthly (30-day) cost  
            local expected_weekly=$(echo "scale=2; $monthly_cost * 7 / 30" | bc -l 2>/dev/null || echo "0")
            local weekly_ratio=$(echo "scale=2; $weekly_cost / $expected_weekly" | bc -l 2>/dev/null || echo "1")
            
            # Alert if weekly cost is 1.5x or more than expected
            if (( $(echo "$weekly_ratio >= 1.5" | bc -l 2>/dev/null || echo 0) )); then
                local increase_percent=$(echo "scale=1; ($weekly_ratio - 1) * 100" | bc -l 2>/dev/null || echo "0")
                
                local issue=$(jq -n \
                    --arg title "Elevated Costs (Weekly): $project_name" \
                    --argjson severity 3 \
                    --arg project_id "$project_id" \
                    --arg project_name "$project_name" \
                    --arg weekly "$weekly_cost" \
                    --arg expected "$expected_weekly" \
                    --arg increase "$increase_percent" \
                    '{
                        title: $title,
                        severity: $severity,
                        expected: ("Weekly cost for \($project_name) should be around $\($expected) based on monthly trend"),
                        actual: ("Last 7 days cost was $\($weekly), \($increase)% higher than expected"),
                        details: ("Project: \($project_name) (\($project_id))\nLast 7 days: $\($weekly)\nExpected (based on monthly): $\($expected)\nIncrease: \($increase)%"),
                        reproduce_hint: "Compare weekly vs monthly costs in BigQuery billing export",
                        next_steps: "1. Review recent changes in resource usage\n2. Check for new deployments or increased workloads\n3. Investigate top services contributing to the increase\n4. Consider cost optimization opportunities"
                    }')
                
                issues=$(echo "$issues" | jq --argjson issue "$issue" '. + [$issue]')
                log "⚠️  Weekly cost elevation for $project_name: \$$weekly_cost vs expected \$$expected_weekly ($increase_percent% increase)"
            fi
        fi
    done
    
    echo "$issues"
}

# Generate budget issues
generate_budget_issues() {
    local total_cost="$1"
    local all_aggregated_data="$2"
    local report_content="$3"
    
    local issues='[]'
    
    # Check if total cost exceeds budget
    if [[ -n "$COST_BUDGET" && "$COST_BUDGET" != "0" ]]; then
        local budget_exceeded=$(echo "$total_cost $COST_BUDGET" | awk '{print ($1 > $2)}')
        if [[ "$budget_exceeded" == "1" ]]; then
            local overage=$(echo "$total_cost $COST_BUDGET" | awk '{printf "%.2f", $1 - $2}')
            local overage_percent=$(echo "$total_cost $COST_BUDGET" | awk '{printf "%.1f", (($1 - $2) / $2) * 100}')
            
            local issue=$(jq -n \
                --arg title "GCP Cost Budget Exceeded" \
                --argjson severity 3 \
                --arg total "$total_cost" \
                --arg budget "$COST_BUDGET" \
                --arg overage "$overage" \
                --arg overage_percent "$overage_percent" \
                --arg report "$report_content" \
                '{
                    title: $title,
                    severity: $severity,
                    expected: ("Total GCP costs should be within budget of $" + $budget),
                    actual: ("Total GCP costs are $" + $total + ", exceeding budget by $" + $overage + " (" + $overage_percent + "%)"),
                    details: $report,
                    reproduce_hint: "Review the cost breakdown in the report to identify high-cost projects and services",
                    next_steps: "1. Review top cost contributors in the report\n2. Identify opportunities for cost optimization\n3. Consider implementing cost controls or budget alerts"
                }')
            
            issues=$(echo "$issues" | jq --argjson issue "$issue" '. + [$issue]')
            log "⚠️  Budget exceeded: \$$total_cost > \$$COST_BUDGET (overage: \$$overage / $overage_percent%)"
        fi
    fi
    
    # Check if any project exceeds percentage threshold
    if [[ -n "$PROJECT_COST_THRESHOLD_PERCENT" && "$PROJECT_COST_THRESHOLD_PERCENT" != "0" ]]; then
        local high_cost_projects=$(echo "$all_aggregated_data" | jq -r \
            --argjson total "$total_cost" \
            --argjson threshold "$PROJECT_COST_THRESHOLD_PERCENT" \
            '[.[] | select((.totalCost / $total * 100) > $threshold)] | .[]' 2>/dev/null)
        
        if [[ -n "$high_cost_projects" ]]; then
            echo "$high_cost_projects" | jq -c '.' | while IFS= read -r project; do
                local proj_name=$(echo "$project" | jq -r '.projectName')
                local proj_cost=$(echo "$project" | jq -r '.totalCost | (. * 100 | round) / 100')
                local proj_percent=$(echo "$proj_cost $total_cost" | awk '{printf "%.1f", ($1 / $2) * 100}')
                
                local issue=$(jq -n \
                    --arg title "GCP Project Cost Threshold Exceeded: $proj_name" \
                    --argjson severity 3 \
                    --arg proj_name "$proj_name" \
                    --arg proj_cost "$proj_cost" \
                    --arg proj_percent "$proj_percent" \
                    --arg threshold "$PROJECT_COST_THRESHOLD_PERCENT" \
                    --arg total "$total_cost" \
                    --arg report "$report_content" \
                    '{
                        title: $title,
                        severity: $severity,
                        expected: ("Individual project costs should be below " + $threshold + "% of total costs"),
                        actual: ("Project \"" + $proj_name + "\" costs $" + $proj_cost + " (" + $proj_percent + "% of total $" + $total + ")"),
                        details: $report,
                        reproduce_hint: "Review project-specific costs in the report",
                        next_steps: "1. Review services and resources in project: " + $proj_name + "\n2. Identify cost optimization opportunities\n3. Consider rightsizing resources or removing unused resources"
                    }')
                
                issues=$(echo "$issues" | jq --argjson issue "$issue" '. + [$issue]')
                log "⚠️  Project \"$proj_name\" exceeds threshold: $proj_percent% > $PROJECT_COST_THRESHOLD_PERCENT% of total cost"
            done
        fi
    fi
    
    # Save issues to file
    echo "$issues" > "$ISSUES_FILE"
    local issue_count=$(echo "$issues" | jq 'length')
    log "Generated $issue_count budget issue(s) in $ISSUES_FILE"
}

# Main function
main() {
    log "Starting GCP Cost Report Generation"
    
    # Log authentication information early
    local gcloud_account=$(gcloud config get-value account 2>/dev/null || echo "")
    if [[ -n "$gcloud_account" ]]; then
        log "Authenticated as: $gcloud_account"
    else
        # Check for service account credentials file
        local creds_file="${GOOGLE_APPLICATION_CREDENTIALS:-}"
        if [[ -z "$creds_file" ]]; then
            # Check default ADC location
            creds_file="$HOME/.config/gcloud/application_default_credentials.json"
        fi
        
        if [[ -f "$creds_file" ]]; then
            local sa_email=$(jq -r '.client_email // empty' "$creds_file" 2>/dev/null || echo "")
            if [[ -n "$sa_email" && "$sa_email" != "null" ]]; then
                log "Using service account from credentials: $sa_email"
            else
                # Try to get account info from Python BigQuery client
                local python_cmd=$(check_python_bq_available)
                if [[ -n "$python_cmd" ]]; then
                    local python_account=$($python_cmd -c "
from google.auth import default
from google.oauth2 import service_account
import sys

try:
    credentials, project = default()
    
    # Check if it's a service account
    if isinstance(credentials, service_account.Credentials):
        if hasattr(credentials, 'service_account_email'):
            print(credentials.service_account_email)
        elif hasattr(credentials, '_service_account_email'):
            print(credentials._service_account_email)
        else:
            # Try to get from the credentials info
            print('Service Account (email not available)')
    elif hasattr(credentials, 'service_account_email'):
        print(credentials.service_account_email)
    elif hasattr(credentials, 'client_email'):
        print(credentials.client_email)
    else:
        # For user credentials, try to get info
        if hasattr(credentials, 'token_uri') and 'serviceaccount' in str(credentials.token_uri):
            print('Service Account (email not available)')
        else:
            # Try to get from token
            try:
                from google.auth.transport.requests import Request
                credentials.refresh(Request())
                if hasattr(credentials, 'id_token'):
                    import json
                    import base64
                    # Decode JWT token to get email
                    parts = credentials.id_token.split('.')
                    if len(parts) >= 2:
                        payload = json.loads(base64.urlsafe_b64decode(parts[1] + '=='))
                        if 'email' in payload:
                            print(payload['email'])
                        else:
                            print('User Account')
                    else:
                        print('User Account')
                else:
                    print('User Account')
            except:
                print('User Account')
except Exception as e:
    print('Application Default Credentials')
" 2>/dev/null)
                    if [[ -n "$python_account" ]]; then
                        log "Authenticated as: $python_account"
                    else
                        log "Using Application Default Credentials (file: $creds_file)"
                    fi
                else
                    log "Using Application Default Credentials (file: $creds_file)"
                fi
            fi
        else
            # Try to get account info from Python BigQuery client
            local python_cmd=$(check_python_bq_available)
            if [[ -n "$python_cmd" ]]; then
                local python_account=$($python_cmd -c "
from google.auth import default
import sys

try:
    credentials, project = default()
    if hasattr(credentials, 'service_account_email'):
        print(credentials.service_account_email)
    elif hasattr(credentials, 'client_email'):
        print(credentials.client_email)
    else:
        print('User/Application Default Credentials')
except Exception as e:
    print('Application Default Credentials')
" 2>/dev/null)
                if [[ -n "$python_account" ]]; then
                    log "Authenticated as: $python_account"
                else
                    log "Using Application Default Credentials"
                fi
            else
                log "Using Application Default Credentials"
            fi
        fi
    fi
    
    # Check for BigQuery access method early
    log "Checking for BigQuery access methods..."
    
    # Check bq CLI first
    if check_bq_available; then
        local bq_path=$(command -v bq 2>/dev/null || echo "not in PATH")
        log "Found 'bq' command at: $bq_path"
        
        # Verify it works
        if bq version &>/dev/null || bq --version &>/dev/null || bq help &>/dev/null; then
            log "✅ 'bq' CLI is working, using it"
            local bq_method="bq"
        else
            log "⚠️  'bq' command found but not working, checking Python..."
            local bq_method=""
        fi
    else
        log "ℹ️  'bq' command not found, checking Python..."
        local bq_method=""
    fi
    
    # Fall back to Python if bq not available or not working
    if [[ -z "$bq_method" ]]; then
        local python_cmd=$(check_python_bq_available)
        if [[ -n "$python_cmd" ]]; then
            log "✅ Python BigQuery client found, using it"
            local bq_method="python"
        else
            echo "Error: No BigQuery access method found"
            echo "Please install one of the following manually:"
            echo "  - bq CLI: gcloud components install bq"
            echo "  - Python library: pip install google-cloud-bigquery"
            exit 1
        fi
    fi
    
    log "Using BigQuery access method: $bq_method"
    
    # Set lookback period from environment variable or default to 30 days
    local LOOKBACK_DAYS="${COST_ANALYSIS_LOOKBACK_DAYS:-30}"
    
    # Validate LOOKBACK_DAYS is a positive integer
    if ! [[ "$LOOKBACK_DAYS" =~ ^[0-9]+$ ]] || [[ "$LOOKBACK_DAYS" -le 0 ]]; then
        log "⚠️  Invalid COST_ANALYSIS_LOOKBACK_DAYS value: $LOOKBACK_DAYS (must be positive integer), defaulting to 30"
        LOOKBACK_DAYS=30
    fi
    
    log "Analysis period: $LOOKBACK_DAYS days"
    
    # BigQuery billing table (format: project-id.dataset_name.table_name)
    # Auto-discover if not provided
    local BILLING_TABLE="${GCP_BILLING_EXPORT_TABLE}"
    if [[ -z "$BILLING_TABLE" ]]; then
        log "GCP_BILLING_EXPORT_TABLE not provided, attempting auto-discovery..."
        BILLING_TABLE=$(discover_billing_table)
        if [[ -z "$BILLING_TABLE" ]]; then
            echo "Error: Could not auto-discover GCP_BILLING_EXPORT_TABLE"
            echo "Please set GCP_BILLING_EXPORT_TABLE environment variable"
            echo "Format: project-id.dataset_name.gcp_billing_export_v1_XXXXXX"
            echo ""
            echo "To find your billing table manually:"
            echo "  bq ls                    # List datasets"
            echo "  bq ls DATASET_NAME       # List tables in dataset"
            exit 1
        fi
        log "✅ Auto-discovered billing table: $BILLING_TABLE"
    fi
    
    # Get date range
    local dates=$(get_date_range)
    IFS='|' read -r start_date end_date <<< "$dates"
    
    log "Report period: $start_date to $end_date (30 days)"
    
    # Re-normalize PROJECT_IDS in case it wasn't normalized earlier
    PROJECT_IDS=$(echo "$PROJECT_IDS" | sed 's/^"//;s/"$//' | xargs)
    
    # If PROJECT_IDS is empty, query all projects from billing table
    if [[ -z "$PROJECT_IDS" ]]; then
        log "GCP_PROJECT_IDS not provided, querying all projects from billing export..."
        PROJECT_IDS=$(get_all_projects_from_billing "$BILLING_TABLE" "$start_date" "$end_date")
        if [[ -z "$PROJECT_IDS" ]]; then
            echo "Error: Could not retrieve projects from billing export table"
            echo "Please set GCP_PROJECT_IDS environment variable with comma-separated project IDs"
            exit 1
        fi
        log "✅ Found projects in billing export: $PROJECT_IDS"
    fi
    
    # Final validation - ensure we have at least one project
    if [[ -z "$PROJECT_IDS" ]]; then
        echo "Error: No projects specified or found"
        echo "Please set GCP_PROJECT_IDS environment variable with comma-separated project IDs"
        exit 1
    fi
    
    log "Target project(s): $PROJECT_IDS"
    log "Billing table: $BILLING_TABLE"
    
    # Process multiple projects
    local all_aggregated_data='[]'
    local successful_projects=0
    local failed_projects=0
    local failed_project_ids=""
    
    IFS=',' read -ra PROJ_ARRAY <<< "$PROJECT_IDS"
    for proj_id in "${PROJ_ARRAY[@]}"; do
        proj_id=$(echo "$proj_id" | xargs)  # trim whitespace
        
        # Skip empty project IDs
        [[ -z "$proj_id" ]] && continue
        
        local proj_data=$(process_project "$proj_id" "$start_date" "$end_date" "$BILLING_TABLE")
        if [[ $? -eq 0 && -n "$proj_data" && "$proj_data" != "[]" ]]; then
            # Merge this project's data with the overall data
            all_aggregated_data=$(echo "$all_aggregated_data" | jq --argjson new "$proj_data" '. + $new')
            ((successful_projects++))
        else
            ((failed_projects++))
            failed_project_ids="${failed_project_ids}${proj_id}, "
        fi
    done
    
    # Re-sort all data by total cost
    all_aggregated_data=$(echo "$all_aggregated_data" | jq 'sort_by(-.totalCost)')
    
    log "Successfully processed $successful_projects project(s)"
    if [[ $failed_projects -gt 0 ]]; then
        failed_project_ids=${failed_project_ids%, }  # Remove trailing comma
        log "⚠️  Failed to retrieve cost data from $failed_projects project(s): $failed_project_ids"
    fi
    
    # Check if we have any data at all
    local total_proj_count=$(echo "$all_aggregated_data" | jq 'length')
    if [[ $total_proj_count -eq 0 ]]; then
        log "❌ No cost data available from any project"
        
        cat > "$REPORT_FILE" << EOF
╔══════════════════════════════════════════════════════════════════════╗
║          GCP COST REPORT - LAST 30 DAYS                             ║
║          Period: $start_date to $end_date                      ║
╚══════════════════════════════════════════════════════════════════════╝

⚠️  NO COST DATA AVAILABLE FROM ANY PROJECT

Projects attempted: ${#PROJ_ARRAY[@]}
Projects with errors: $failed_projects

Failed projects: $failed_project_ids

Possible reasons:
• No costs incurred during this period
• Insufficient permissions (need BigQuery Data Viewer role)
• Billing export not configured in BigQuery
• Billing table path incorrect

Please verify:
1. Billing export is enabled and configured
2. You have BigQuery Data Viewer role on the billing project
3. Costs have been incurred in the last 30 days
4. GCP_BILLING_EXPORT_TABLE is set correctly

EOF
        log "Report saved to: $REPORT_FILE"
        exit 0
    fi
    
    # Calculate total cost (rounded to 2 decimal places)
    local total_cost=$(echo "$all_aggregated_data" | jq '[.[].totalCost] | add // 0 | (. * 100 | round) / 100')
    
    log "Total cost across all projects: \$$total_cost"
    
    # Get time-series data FIRST (before generating reports so it can be included)
    log "Fetching time-series cost data (last $LOOKBACK_DAYS days)..."
    local ts_start_date=$(date -u -d "${LOOKBACK_DAYS} days ago" +"%Y-%m-%d" 2>/dev/null || date -u -v-${LOOKBACK_DAYS}d +"%Y-%m-%d" 2>/dev/null)
    
    log "DEBUG: Time-series date range: $ts_start_date to $end_date"
    
    # Build project filter for time-series query
    local ts_project_filter=""
    if [[ -n "$PROJECT_IDS" ]]; then
        local project_list=$(echo "$PROJECT_IDS" | tr ',' '\n' | sed "s/^/'/;s/$/'/" | tr '\n' ',' | sed 's/,$//')
        ts_project_filter="AND project.id IN ($project_list)"
        log "DEBUG: Time-series project filter: $ts_project_filter"
    fi
    
    local timeseries_data=$(get_timeseries_cost_data "$BILLING_TABLE" "$ts_start_date" "$end_date" "$ts_project_filter")
    local ts_row_count=$(echo "$timeseries_data" | jq 'length' 2>/dev/null || echo "0")
    
    log "DEBUG: Time-series query returned $ts_row_count rows"
    
    # Prepare aggregated time-series data for display (outside of conditional so it's always available)
    local aggregated_ts='[]'
    local ts_date_ranges='{}'
    
    if [[ $ts_row_count -gt 0 ]]; then
        log "✅ Retrieved $ts_row_count time-series cost records"
        
        # Prepare date ranges for aggregation
        declare -a daily_dates
        for i in {0..6}; do
            daily_dates[$i]=$(date -u -d "${i} days ago" +"%Y-%m-%d" 2>/dev/null || date -u -v-${i}d +"%Y-%m-%d" 2>/dev/null)
        done
        
        local week_start=$(date -u -d '7 days ago' +"%Y-%m-%d" 2>/dev/null || date -u -v-7d +"%Y-%m-%d" 2>/dev/null)
        local month_start=$(date -u -d '30 days ago' +"%Y-%m-%d" 2>/dev/null || date -u -v-30d +"%Y-%m-%d" 2>/dev/null)
        
        ts_date_ranges=$(jq -n \
            --arg d0 "${daily_dates[0]}" \
            --arg d1 "${daily_dates[1]}" \
            --arg d2 "${daily_dates[2]}" \
            --arg d3 "${daily_dates[3]}" \
            --arg d4 "${daily_dates[4]}" \
            --arg d5 "${daily_dates[5]}" \
            --arg d6 "${daily_dates[6]}" \
            --arg week_start "$week_start" \
            --arg week_end "$end_date" \
            --arg month_start "$month_start" \
            --arg month_end "$end_date" \
            --arg lookback_start "$ts_start_date" \
            --arg lookback_end "$end_date" \
            --argjson lookback_days "$LOOKBACK_DAYS" \
            '{
                daily: [$d6, $d5, $d4, $d3, $d2, $d1, $d0],
                weekly: {start: $week_start, end: $week_end},
                monthly: {start: $month_start, end: $month_end},
                lookback: {start: $lookback_start, end: $lookback_end, days: $lookback_days}
            }')
        
        # Aggregate time-series data
        aggregated_ts=$(aggregate_timeseries_costs "$timeseries_data" "$ts_date_ranges")
        log "✅ Aggregated time-series data ready for display"
    else
        log "⚠️  No time-series data retrieved - time-based cost tracking unavailable"
    fi
    
    # Generate reports (now with time-series data available)
    if [[ "$OUTPUT_FORMAT" == "csv" || "$OUTPUT_FORMAT" == "all" ]]; then
        generate_csv_report "$all_aggregated_data"
    fi
    
    if [[ "$OUTPUT_FORMAT" == "json" || "$OUTPUT_FORMAT" == "all" ]]; then
        generate_json_report "$all_aggregated_data" "$start_date" "$end_date" "$total_cost"
    fi
    
    if [[ "$OUTPUT_FORMAT" == "table" || "$OUTPUT_FORMAT" == "all" ]]; then
        generate_table_report "$all_aggregated_data" "$start_date" "$end_date" "$total_cost"
        
        # Add time-series section if we have the data
        log "DEBUG: Checking time-series data..."
        log "DEBUG: aggregated_ts length: $(echo "$aggregated_ts" | jq 'length' 2>/dev/null || echo 'N/A')"
        log "DEBUG: aggregated_ts first 200 chars: $(echo "$aggregated_ts" | head -c 200 || echo 'empty')"
        
        if [[ -n "$aggregated_ts" && "$aggregated_ts" != "[]" ]]; then
            log "DEBUG: Calling generate_timeseries_section"
            generate_timeseries_section "$aggregated_ts" "$ts_date_ranges" "$REPORT_FILE"
        else
            log "DEBUG: Skipping time-series section - no data"
        fi
        
        log "Report saved to: $REPORT_FILE"
        echo ""
        cat "$REPORT_FILE"
    fi
    
    # Now detect anomalies from the time-series data (for issue generation)
    # Detect anomalies from the already-fetched time-series data
    local anomaly_issues='[]'
    if [[ $ts_row_count -eq 0 ]]; then
        # Generate informational issue about missing time-series data
        local ts_details="Could not retrieve daily cost data for period ${ts_start_date} to ${end_date}.\n\nThis means:\n- Daily spending breakdown unavailable\n- Cost spike detection disabled\n- Trend analysis not possible\n\nPossible causes:\n- Query error (check logs)\n- No costs in this time period\n- BigQuery permissions issue"
        
        local ts_issue=$(jq -n \
            --arg title "Time-Series Cost Data Unavailable" \
            --argjson severity 4 \
            --arg details "$ts_details" \
            '{
                title: $title,
                severity: $severity,
                expected: "Time-series cost query should return daily cost data for trend analysis",
                actual: "Time-series query returned 0 rows",
                details: $details,
                reproduce_hint: "Check script logs for time-series query errors or warnings",
                next_steps: "1. Review DEBUG logs for time-series query errors\n2. Verify costs exist in the specified date range\n3. Check BigQuery permissions\n4. Test time-series query manually in BigQuery Console"
            }')
        
        anomaly_issues=$(echo "$anomaly_issues" | jq --argjson issue "$ts_issue" '. + [$issue]')
    elif [[ -n "$aggregated_ts" && "$aggregated_ts" != "[]" ]]; then
        # Detect anomalies from the aggregated time-series data
        log "Analyzing for cost anomalies and deviations..."
        anomaly_issues=$(detect_timeseries_anomalies "$aggregated_ts" "2.0")
        local anomaly_count=$(echo "$anomaly_issues" | jq 'length' 2>/dev/null || echo "0")
        log "Detected $anomaly_count cost anomalie(s)"
    fi
    
    # Check budget thresholds and generate issues (only if we have data)
    if [[ $total_proj_count -gt 0 ]]; then
        local report_content=""
        if [[ -f "$REPORT_FILE" ]]; then
            report_content=$(cat "$REPORT_FILE")
        fi
        generate_budget_issues "$total_cost" "$all_aggregated_data" "$report_content"
        
        # Merge anomaly issues with budget issues
        if [[ -n "$anomaly_issues" && "$anomaly_issues" != "[]" ]]; then
            local combined_issues=$(jq -s '.[0] + .[1]' "$ISSUES_FILE" <(echo "$anomaly_issues") 2>&1)
            if [[ $? -eq 0 && -n "$combined_issues" ]]; then
                echo "$combined_issues" > "$ISSUES_FILE"
                local total_issues=$(echo "$combined_issues" | jq 'length')
                local anomaly_count_actual=$(echo "$anomaly_issues" | jq 'length')
                log "Total issues generated: $total_issues (including $anomaly_count_actual anomaly/warning issues)"
            else
                log "⚠️  Failed to merge anomaly issues with budget issues: $combined_issues"
                log "Budget issues preserved in $ISSUES_FILE"
            fi
        fi
    else
        # No data, create empty issues file
        echo '[]' > "$ISSUES_FILE"
    fi
    
    log "✅ Cost report generation complete!"
    log "   Successful projects: $successful_projects"
    if [[ $failed_projects -gt 0 ]]; then
        log "   ⚠️  Failed projects: $failed_projects ($failed_project_ids)"
    fi
}

main "$@"



