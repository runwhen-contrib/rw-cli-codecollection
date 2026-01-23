*** Settings ***
Documentation       GCP cost management toolkit: generate historical cost reports by service/project using BigQuery billing export
Metadata            Author    stewartshea
Metadata            Display Name    GCP Project Cost Health & Reporting
Metadata            Supports    GCP    Cost Optimization    Cost Management    Cost Reporting    BigQuery
Force Tags          GCP    Cost Optimization    Cost Management    BigQuery

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections
Suite Setup         Suite Initialization


*** Tasks ***
Generate GCP Cost Report By Service and Project
    [Documentation]    Generates a detailed cost breakdown report for the last 30 days showing actual spending by project and GCP service using BigQuery billing export
    [Tags]    GCP    Cost Analysis    Cost Management    Reporting    access:read-only
    ${cost_report}=    RW.CLI.Run Bash File
    ...    bash_file=gcp_cost_historical_report.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${cost_report.stdout}

    # Display cost report summary
    ${report_summary}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "gcp_cost_report.txt" ]; then echo ""; echo "📊 GCP Cost Report Summary:"; echo "============================"; head -40 gcp_cost_report.txt; else echo "No cost report available"; fi
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    
    RW.Core.Add Pre To Report    ${report_summary.stdout}

    # Check if JSON report exists and parse top spenders
    ${json_check}=    RW.CLI.Run Bash File
    ...    bash_file=display_top_projects.sh
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${json_check.stdout}
    
    # Check for budget issues
    ${cost_issues_json}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "gcp_cost_issues.json" ]; then cat gcp_cost_issues.json; else echo "[]"; fi
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    
    ${cost_issues_list}=    Evaluate    json.loads(r'''${cost_issues_json.stdout}''')    json
    FOR    ${issue}    IN    @{cost_issues_list}
        ${severity}=    Set Variable    ${issue['severity']}
        ${title}=    Set Variable    ${issue['title']}
        ${expected}=    Set Variable    ${issue['expected']}
        ${actual}=    Set Variable    ${issue['actual']}
        ${details}=    Set Variable    ${issue['details']}
        ${reproduce_hint}=    Set Variable    ${issue.get('reproduce_hint', '')}
        ${next_steps}=    Set Variable    ${issue['next_steps']}
        RW.Core.Add Issue
        ...    severity=${severity}
        ...    expected=${expected}
        ...    actual=${actual}
        ...    title=${title}
        ...    details=${details}
        ...    reproduce_hint=${reproduce_hint}
        ...    next_steps=${next_steps}
    END

Analyze GCP Network Costs By SKU
    [Documentation]    Analyzes network-related costs broken down by SKU, showing daily spend for the last 7 days, weekly, monthly, and three-month spend. Detects cost anomalies and deviations.
    [Tags]    GCP    Network    Cost Analysis    Egress    Ingress    access:read-only
    ${network_cost}=    RW.CLI.Run Bash File
    ...    bash_file=gcp_network_cost_analysis.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${network_cost.stdout}
    
    # Display network cost report summary
    ${network_summary}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "gcp_network_cost_report.txt" ]; then echo ""; echo "🌐 GCP Network Cost Report:"; echo "============================"; head -60 gcp_network_cost_report.txt; else echo "No network cost report available"; fi
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    
    RW.Core.Add Pre To Report    ${network_summary.stdout}
    
    # Check for network cost issues and anomalies
    ${network_issues_json}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "gcp_network_cost_issues.json" ]; then cat gcp_network_cost_issues.json; else echo "[]"; fi
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    
    ${network_issues_list}=    Evaluate    json.loads(r'''${network_issues_json.stdout}''')    json
    FOR    ${issue}    IN    @{network_issues_list}
        ${severity}=    Set Variable    ${issue['severity']}
        ${title}=    Set Variable    ${issue['title']}
        ${expected}=    Set Variable    ${issue['expected']}
        ${actual}=    Set Variable    ${issue['actual']}
        ${details}=    Set Variable    ${issue['details']}
        ${reproduce_hint}=    Set Variable    ${issue.get('reproduce_hint', '')}
        ${next_steps}=    Set Variable    ${issue['next_steps']}
        RW.Core.Add Issue
        ...    severity=${severity}
        ...    expected=${expected}
        ...    actual=${actual}
        ...    title=${title}
        ...    details=${details}
        ...    reproduce_hint=${reproduce_hint}
        ...    next_steps=${next_steps}
    END

Get GCP Cost Optimization Recommendations
    [Documentation]    Fetches COST-RELATED recommendations from GCP Recommender API (committed use discounts, idle resources, rightsizing, etc.). Filters out non-cost recommendations like security/IAM suggestions.
    [Tags]    GCP    Cost Optimization    Recommendations    FinOps    access:read-only
    ${recommendations}=    RW.CLI.Run Bash File
    ...    bash_file=gcp_recommendations.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=300
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${recommendations.stdout}
    
    # Parse recommendations and create issues
    ${recommendations_json}=    RW.CLI.Run Cli
    ...    cmd=if [ -f "gcp_recommendations_issues.json" ]; then cat gcp_recommendations_issues.json; else echo "[]"; fi
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    
    ${recommendations_list}=    Evaluate    json.loads(r'''${recommendations_json.stdout}''')    json
    FOR    ${rec}    IN    @{recommendations_list}
        ${severity}=    Set Variable    ${rec['severity']}
        ${title}=    Set Variable    ${rec['title']}
        ${details}=    Evaluate    json.dumps($rec['details'], indent=2)    json
        ${next_steps}=    Set Variable    ${rec['next_steps']}
        RW.Core.Add Issue
        ...    severity=${severity}
        ...    expected=GCP resources should be optimized based on usage patterns
        ...    actual=GCP Recommender found optimization opportunity: ${title}
        ...    title=${title}
        ...    details=${details}
        ...    next_steps=${next_steps}
    END


*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account json used to authenticate with GCP APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID", ... super secret stuff ...}
    ${GCP_PROJECT_IDS}=    RW.Core.Import User Variable    GCP_PROJECT_IDS
    ...    type=string
    ...    description=Comma-separated list of GCP project IDs to analyze for cost optimization (e.g., "project-1,project-2,project-3"). If left blank, will assess all projects found in the billing export.
    ...    pattern=[\w,-]*
    ...    default=""
    ${GCP_BILLING_EXPORT_TABLE}=    RW.Core.Import User Variable    GCP_BILLING_EXPORT_TABLE
    ...    type=string
    ...    description=BigQuery table path for billing export in format: project-id.dataset_name.gcp_billing_export_v1_XXXXXX (optional - will auto-discover if not provided)
    ...    pattern=.*
    ...    default=""
    ${COST_ANALYSIS_LOOKBACK_DAYS}=    RW.Core.Import User Variable    COST_ANALYSIS_LOOKBACK_DAYS
    ...    type=string
    ...    description=Number of days to look back for cost analysis (default: 30)
    ...    pattern=\d+
    ...    default=30
    ${GCP_COST_BUDGET}=    RW.Core.Import User Variable    GCP_COST_BUDGET
    ...    type=string
    ...    description=Optional budget threshold in USD. A severity 3 issue will be raised if total costs exceed this amount. Leave at 0 to disable.
    ...    pattern=\d+
    ...    default=10000
    ${GCP_PROJECT_COST_THRESHOLD_PERCENT}=    RW.Core.Import User Variable    GCP_PROJECT_COST_THRESHOLD_PERCENT
    ...    type=string
    ...    description=Optional percentage threshold (0-100). A severity 3 issue will be raised if any single project exceeds this percentage of total costs. Leave at 0 to disable.
    ...    pattern=\d+
    ...    default=25
    ${NETWORK_COST_THRESHOLD_MONTHLY}=    RW.Core.Import User Variable    NETWORK_COST_THRESHOLD_MONTHLY
    ...    type=string
    ...    description=Minimum monthly network cost (in USD) to trigger alerts. SKUs below this threshold are excluded from analysis to reduce noise and BigQuery costs.
    ...    pattern=\d+
    ...    default=200
    ${NETWORK_COST_SEVERITY_MEDIUM_MULTIPLIER}=    RW.Core.Import User Variable    NETWORK_COST_SEVERITY_MEDIUM_MULTIPLIER
    ...    type=string
    ...    description=Multiplier for Medium severity threshold. Medium alerts trigger at (base_threshold × multiplier). Default: 5 results in Medium at $1000/month with $200 base.
    ...    pattern=\d+
    ...    default=5
    ${NETWORK_COST_SEVERITY_HIGH_MULTIPLIER}=    RW.Core.Import User Variable    NETWORK_COST_SEVERITY_HIGH_MULTIPLIER
    ...    type=string
    ...    description=Multiplier for High severity threshold. High alerts trigger at (base_threshold × multiplier). Default: 20 results in High at $4000/month with $200 base.
    ...    pattern=\d+
    ...    default=20
    ${OS_PATH}=    Get Environment Variable    PATH
    
    # Set suite variables
    Set Suite Variable    ${GCP_PROJECT_IDS}    ${GCP_PROJECT_IDS}
    Set Suite Variable    ${GCP_BILLING_EXPORT_TABLE}    ${GCP_BILLING_EXPORT_TABLE}
    Set Suite Variable    ${COST_ANALYSIS_LOOKBACK_DAYS}    ${COST_ANALYSIS_LOOKBACK_DAYS}
    Set Suite Variable    ${GCP_COST_BUDGET}    ${GCP_COST_BUDGET}
    Set Suite Variable    ${GCP_PROJECT_COST_THRESHOLD_PERCENT}    ${GCP_PROJECT_COST_THRESHOLD_PERCENT}
    Set Suite Variable    ${NETWORK_COST_THRESHOLD_MONTHLY}    ${NETWORK_COST_THRESHOLD_MONTHLY}
    Set Suite Variable    ${NETWORK_COST_SEVERITY_MEDIUM_MULTIPLIER}    ${NETWORK_COST_SEVERITY_MEDIUM_MULTIPLIER}
    Set Suite Variable    ${NETWORK_COST_SEVERITY_HIGH_MULTIPLIER}    ${NETWORK_COST_SEVERITY_HIGH_MULTIPLIER}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    
    # Create environment variables for the bash script
    # Build dictionary conditionally to handle empty strings properly
    ${env_dict}=    Create Dictionary
    Set To Dictionary    ${env_dict}    GOOGLE_APPLICATION_CREDENTIALS    ./${gcp_credentials.key}
    Set To Dictionary    ${env_dict}    COST_ANALYSIS_LOOKBACK_DAYS    ${COST_ANALYSIS_LOOKBACK_DAYS}
    Set To Dictionary    ${env_dict}    OUTPUT_FORMAT    all
    Set To Dictionary    ${env_dict}    PATH    ${OS_PATH}
    IF    $GCP_PROJECT_IDS != ""
        Set To Dictionary    ${env_dict}    GCP_PROJECT_IDS    ${GCP_PROJECT_IDS}
    END
    IF    $GCP_BILLING_EXPORT_TABLE != ""
        Set To Dictionary    ${env_dict}    GCP_BILLING_EXPORT_TABLE    ${GCP_BILLING_EXPORT_TABLE}
    END
    IF    $GCP_COST_BUDGET != "" and $GCP_COST_BUDGET != "0"
        Set To Dictionary    ${env_dict}    GCP_COST_BUDGET    ${GCP_COST_BUDGET}
    END
    IF    $GCP_PROJECT_COST_THRESHOLD_PERCENT != "" and $GCP_PROJECT_COST_THRESHOLD_PERCENT != "0"
        Set To Dictionary    ${env_dict}    GCP_PROJECT_COST_THRESHOLD_PERCENT    ${GCP_PROJECT_COST_THRESHOLD_PERCENT}
    END
    IF    $NETWORK_COST_THRESHOLD_MONTHLY != "" and $NETWORK_COST_THRESHOLD_MONTHLY != "0"
        Set To Dictionary    ${env_dict}    NETWORK_COST_THRESHOLD_MONTHLY    ${NETWORK_COST_THRESHOLD_MONTHLY}
    END
    IF    $NETWORK_COST_SEVERITY_MEDIUM_MULTIPLIER != "" and $NETWORK_COST_SEVERITY_MEDIUM_MULTIPLIER != "0"
        Set To Dictionary    ${env_dict}    NETWORK_COST_SEVERITY_MEDIUM_MULTIPLIER    ${NETWORK_COST_SEVERITY_MEDIUM_MULTIPLIER}
    END
    IF    $NETWORK_COST_SEVERITY_HIGH_MULTIPLIER != "" and $NETWORK_COST_SEVERITY_HIGH_MULTIPLIER != "0"
        Set To Dictionary    ${env_dict}    NETWORK_COST_SEVERITY_HIGH_MULTIPLIER    ${NETWORK_COST_SEVERITY_HIGH_MULTIPLIER}
    END
    Set Suite Variable    ${env}    ${env_dict}
    
    # Validate gcloud CLI authentication and permissions
    ${auth_check}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && gcloud config get-value account
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=30
    ...    include_in_history=false
    
    Log    Current GCP Account: ${auth_check.stdout}
    
    # Validate access to target projects
    ${project_validation}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && if [ -n "$GCP_PROJECT_IDS" ]; then echo "Validating access to target projects:"; for proj_id in $(echo "$GCP_PROJECT_IDS" | tr ',' ' '); do echo "Checking project: $proj_id"; gcloud projects describe "$proj_id" --format="table(projectId,name,projectNumber)" 2>/dev/null || echo "❌ Cannot access project: $proj_id"; done; else echo "No projects specified"; fi
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=60
    ...    include_in_history=false
    
    Log    Project Access Validation: ${project_validation.stdout}
    
    # Check BigQuery permissions
    ${bq_check}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && echo "Checking BigQuery access:"; bq ls --max_results=1 2>/dev/null && echo "✅ BigQuery access granted" || echo "❌ BigQuery access denied"
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=30
    ...    include_in_history=false
    
    Log    BigQuery Access Check: ${bq_check.stdout}



