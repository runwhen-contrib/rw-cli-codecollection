*** Settings ***
Documentation       Performs a health check on Azure Service Bus instances and the components using them, generating a report of issues and next steps.
Metadata            Author    stewartshea
Metadata            Display Name    Azure Service Bus Health
Metadata            Supports    Azure    ServiceBus 

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             DateTime
Suite Setup         Suite Initialization


*** Tasks ***
Check for Resource Health Issues Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch a list of issues that might affect the service bus instance
    [Tags]    azure    servicebus    resourcehealth   access:read-only
    ${resource_health}=    RW.CLI.Run Bash File
    ...    bash_file=service_bus_resource_health.sh
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${resource_health.stdout}
    ${timestamp}=    Datetime.Get Current Date
    
    # Add detailed resource health JSON data to report
    ${health_data}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_health.json | jq -r 'if . == {} then "No resource health data available" else . end'
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    RW.Core.Add Pre To Report    \n----------\nResource Health Details:\n${health_data.stdout}
    IF    "${resource_health.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Warnings/Errors running task.
        ...    severity=3
        ...    next_steps=Check debug logs in Report
        ...    expected=No stderr output
        ...    actual=stderr encountered
        ...    reproduce_hint=${resource_health.cmd}
        ...    details=${resource_health.stderrt}
        ...    observed_at=${timestamp}
    END

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_health.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0 
        IF    "${issue_list["properties"]["title"]}" != "Available"
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=Azure resources should be available for Service Bus `${SB_NAMESPACE_NAME}` in `${AZ_RESOURCE_GROUP}`
            ...    actual=Azure resources are unhealthy for Service Bus `${SB_NAMESPACE_NAME}` in `${AZ_RESOURCE_GROUP}`
            ...    title=Azure reports an `${issue_list["properties"]["title"]}` Issue for Service Bus `${SB_NAMESPACE_NAME}` in `${AZ_RESOURCE_GROUP}`
            ...    reproduce_hint=${resource_health.cmd}
            ...    details=${issue_list}
            ...    next_steps=Please escalate to the Azure service owner or check back later.
            ...    observed_at=${issue_list["properties"]["occuredTime"]}
        END
    ELSE
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Azure resources health should be enabled for Service Bus `${SB_NAMESPACE_NAME}` in `${AZ_RESOURCE_GROUP}`
        ...    actual=Azure resource health appears unavailable for Service Bus `${SB_NAMESPACE_NAME}` in `${AZ_RESOURCE_GROUP}`
        ...    title=Azure resource health is unavailable for Service Bus `${SB_NAMESPACE_NAME}` in `${AZ_RESOURCE_GROUP}`
        ...    reproduce_hint=${resource_health.cmd}
        ...    details=${issue_list}
        ...    next_steps=Please escalate to the Azure service owner to enable provider Microsoft.ResourceHealth.
        ...    observed_at=${timestamp}
    END

Check Configuration Health for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch the details and health of the service bus configuration
    [Tags]    servicebus    logs    config    access:read-only
    ${config_health}=    RW.CLI.Run Bash File
    ...    bash_file=service_bus_config_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${config_health.stdout}
    ${timestamp}=    Datetime.Get Current Date
    
    # Add detailed configuration JSON data to report
    ${config_data}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_config_health.json | jq -r 'if . == {} then "No configuration data available" else . end'
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    RW.Core.Add Pre To Report    \n----------\nConfiguration Health Details:\n${config_data.stdout}
    
    IF    "${config_health.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Warnings/Errors running task.
        ...    severity=3
        ...    next_steps=Check debug logs in Report
        ...    expected=No stderr output
        ...    actual=stderr encountered
        ...    reproduce_hint=${config_health.cmd}
        ...    details=${config_health.stderrt}
        ...    observed_at=${timestamp}
    END
    ${report}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_namespace.txt
    RW.Core.Add Pre To Report    ${report.stdout} 
      
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_config_health.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=Service Bus `${SB_NAMESPACE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has a healthy configuration
            ...    actual=Service Bus `${SB_NAMESPACE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has configuration recommendations
            ...    reproduce_hint=${config_health.cmd}
            ...    details=${item["details"]}        
            ...    observed_at=${timestamp}
        END
    END

Check Metrics for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Analyze Service Bus metrics for potential issues
    [Tags]    servicebus    metrics    performance    access:read-only
    ${metrics}=    RW.CLI.Run Bash File
    ...    bash_file=service_bus_metrics.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${metrics.stdout}
    
    # Add detailed metrics JSON data to report
    ${metrics_raw_data}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_metrics.json | jq -r 'if . == {} then "No metrics data available" else . end'
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    RW.Core.Add Pre To Report    \n----------\nRaw Metrics Data:\n${metrics_raw_data.stdout}
    
    # Add formatted metrics data to report
    ${metrics_data}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_metrics.json | jq -r 'to_entries | map("\\n**\\(.key)**:\\n" + (.value.value[0].timeseries[0].data | map("  Time: \\(.timeStamp) | Total: \\(.total // "N/A") | Avg: \\(.average // "N/A") | Max: \\(.maximum // "N/A")") | join("\\n"))) | join("\\n")'
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    RW.Core.Add Pre To Report    \n----------\nFormatted Metrics Data:\n${metrics_data.stdout}
    
    ${timestamp}=    Datetime.Get Current Date
    IF    "${metrics.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Warnings/Errors running task.
        ...    severity=3
        ...    next_steps=Check debug logs in Report
        ...    expected=No stderr output
        ...    actual=stderr encountered
        ...    reproduce_hint=${metrics.cmd}
        ...    details=${metrics.stderr}
        ...    observed_at=${timestamp}
    END

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_metrics_issues.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=Service Bus `${SB_NAMESPACE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has healthy metrics
            ...    actual=Service Bus `${SB_NAMESPACE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has metric anomalies
            ...    reproduce_hint=${metrics.cmd}
            ...    details=${item["details"]}        
            ...    observed_at=${timestamp}
        END
    END

Check Queue Health for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Analyze Service Bus queues for health issues
    [Tags]    servicebus    queues    messages    access:read-only
    ${queue_health}=    RW.CLI.Run Bash File
    ...    bash_file=service_bus_queue_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${queue_health.stdout}
    ${timestamp}=    Datetime.Get Current Date
    
    # Add detailed queue JSON data to report
    ${queue_data}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_queues.json | jq -r 'if . == {} then "No queue data available" else . end'
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    RW.Core.Add Pre To Report    \n----------\nQueue Details:\n${queue_data.stdout}
    IF    "${queue_health.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Warnings/Errors running task.
        ...    severity=3
        ...    next_steps=Check debug logs in Report
        ...    expected=No stderr output
        ...    actual=stderr encountered
        ...    reproduce_hint=${queue_health.cmd}
        ...    details=${queue_health.stderr}
        ...    observed_at=${timestamp}
    END

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_queue_issues.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=Service Bus `${SB_NAMESPACE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has healthy queues
            ...    actual=Service Bus `${SB_NAMESPACE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has queue issues
            ...    reproduce_hint=${queue_health.cmd}
            ...    details=${item["details"]}        
            ...    observed_at=${item["observed_at"]}
        END
    END

Check Topic Health for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Analyze Service Bus topics and subscriptions for health issues
    [Tags]    servicebus    topics    subscriptions    access:read-only
    ${topic_health}=    RW.CLI.Run Bash File
    ...    bash_file=service_bus_topic_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${topic_health.stdout}
    ${timestamp}=    Datetime.Get Current Date
    
    # Add detailed topic JSON data to report
    ${topic_data}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_topics.json | jq -r 'if . == {} then "No topic data available" else . end'
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    RW.Core.Add Pre To Report    \n----------\nTopic Details:\n${topic_data.stdout}
    IF    "${topic_health.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Warnings/Errors running task.
        ...    severity=3
        ...    next_steps=Check debug logs in Report
        ...    expected=No stderr output
        ...    actual=stderr encountered
        ...    reproduce_hint=${topic_health.cmd}
        ...    details=${topic_health.stderr}
        ...    observed_at=${timestamp}
    END

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_topic_issues.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=Service Bus `${SB_NAMESPACE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has healthy topics and subscriptions
            ...    actual=Service Bus `${SB_NAMESPACE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has topic/subscription issues
            ...    reproduce_hint=${topic_health.cmd}
            ...    details=${item["details"]}        
            ...    observed_at=${item["observed_at"]}
        END
    END

Check Log Analytics for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Query Log Analytics for Service Bus related logs and errors
    [Tags]    servicebus    logs    diagnostics    access:read-only
    ${log_analytics}=    RW.CLI.Run Bash File
    ...    bash_file=service_bus_log_analytics.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${log_analytics.stdout}
    ${timestamp}=    Datetime.Get Current Date
    
    # Add detailed log analytics JSON data to report
    ${log_data}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_logs.json | jq -r 'if . == {} then "No log data available" else . end'
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    RW.Core.Add Pre To Report    \n----------\nLog Analytics Data:\n${log_data.stdout}
    IF    "${log_analytics.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Warnings/Errors running task.
        ...    severity=3
        ...    next_steps=Check debug logs in Report
        ...    expected=No stderr output
        ...    actual=stderr encountered
        ...    reproduce_hint=${log_analytics.cmd}
        ...    details=${log_analytics.stderr}
        ...    observed_at=${timestamp}
    END

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_log_issues.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=Service Bus `${SB_NAMESPACE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has no log issues
            ...    actual=Service Bus `${SB_NAMESPACE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has log issues
            ...    reproduce_hint=${log_analytics.cmd}
            ...    details=${item["details"]}        
            ...    observed_at=${item["observed_at"]}
        END
    END

Check Capacity and Quota Headroom for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Analyze Service Bus capacity utilization and quota headroom
    [Tags]    servicebus    capacity    quota    access:read-only
    ${capacity}=    RW.CLI.Run Bash File
    ...    bash_file=service_bus_capacity.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${capacity.stdout}
    ${timestamp}=    Datetime.Get Current Date
    
    # Add detailed capacity JSON data to report
    ${capacity_data}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_capacity.json | jq -r 'if . == {} then "No capacity data available" else . end'
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    RW.Core.Add Pre To Report    \n----------\nCapacity Details:\n${capacity_data.stdout}
    IF    "${capacity.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Warnings/Errors running task.
        ...    severity=3
        ...    next_steps=Check debug logs in Report
        ...    expected=No stderr output
        ...    actual=stderr encountered
        ...    reproduce_hint=${capacity.cmd}
        ...    details=${capacity.stderr}
        ...    observed_at=${timestamp}
    END

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_capacity_issues.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=Service Bus `${SB_NAMESPACE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has sufficient capacity
            ...    actual=Service Bus `${SB_NAMESPACE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has capacity concerns
            ...    reproduce_hint=${capacity.cmd}
            ...    details=${item["details"]}        
            ...    observed_at=${item["observed_at"]}
        END
    END

Check Geo-Disaster Recovery for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Check the geo-disaster recovery configuration and health
    [Tags]    servicebus    disaster-recovery    geo-replication    access:read-only
    ${dr}=    RW.CLI.Run Bash File
    ...    bash_file=service_bus_disaster_recovery.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${dr.stdout}
    ${timestamp}=    Datetime.Get Current Date
    
    # Add detailed disaster recovery JSON data to report
    ${dr_data}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_dr.json | jq -r 'if . == {} then "No disaster recovery data available" else . end'
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    RW.Core.Add Pre To Report    \n----------\nDisaster Recovery Configuration:\n${dr_data.stdout}
    IF    "${dr.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Warnings/Errors running task.
        ...    severity=3
        ...    next_steps=Check debug logs in Report
        ...    expected=No stderr output
        ...    actual=stderr encountered
        ...    reproduce_hint=${dr.cmd}
        ...    details=${dr.stderr}
        ...    observed_at=${timestamp}
    END

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_dr_issues.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=Service Bus `${SB_NAMESPACE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has proper disaster recovery
            ...    actual=Service Bus `${SB_NAMESPACE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has disaster recovery concerns
            ...    reproduce_hint=${dr.cmd}
            ...    details=${item["details"]}        
            ...    observed_at=${timestamp}
        END
    END

Check Security Configuration for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Audit SAS keys and RBAC assignments for security best practices
    [Tags]    servicebus    security    rbac    access:read-only
    ${security}=    RW.CLI.Run Bash File
    ...    bash_file=service_bus_security_audit.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${security.stdout}
    ${timestamp}=    Datetime.Get Current Date
    
    # Add detailed security JSON data to report
    ${security_data}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_security.json | jq -r 'if . == {} then "No security data available" else . end'
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    RW.Core.Add Pre To Report    \n----------\nSecurity Configuration:\n${security_data.stdout}
    IF    "${security.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Warnings/Errors running task.
        ...    severity=3
        ...    next_steps=Check debug logs in Report
        ...    expected=No stderr output
        ...    actual=stderr encountered
        ...    reproduce_hint=${security.cmd}
        ...    details=${security.stderr}
        ...    observed_at=${timestamp}
    END

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_security_issues.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=Service Bus `${SB_NAMESPACE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has secure configuration
            ...    actual=Service Bus `${SB_NAMESPACE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has security concerns
            ...    reproduce_hint=${security.cmd}
            ...    details=${item["details"]}        
            ...    observed_at=${timestamp}
        END
    END

Discover Related Resources for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Discover and map Azure resources related to the Service Bus namespace
    [Tags]    servicebus    related-resources    mapping    access:read-only
    ${related}=    RW.CLI.Run Bash File
    ...    bash_file=service_bus_related_resources.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${related.stdout}
    ${timestamp}=    Datetime.Get Current Date
    
    # Add detailed related resources JSON data to report
    ${related_data}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_related_resources.json | jq -r 'if . == {} then "No related resources data available" else . end'
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    RW.Core.Add Pre To Report    \n----------\nRelated Resources:\n${related_data.stdout}
    IF    "${related.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Warnings/Errors running task.
        ...    severity=3
        ...    next_steps=Check debug logs in Report
        ...    expected=No stderr output
        ...    actual=stderr encountered
        ...    reproduce_hint=${related.cmd}
        ...    details=${related.stderr}
        ...    observed_at=${timestamp}
    END

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_related_resources_issues.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=Service Bus `${SB_NAMESPACE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has proper related resources
            ...    actual=Service Bus `${SB_NAMESPACE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has related resource concerns
            ...    reproduce_hint=${related.cmd}
            ...    details=${item["details"]}        
            ...    observed_at=${timestamp}
        END
    END

Test Connectivity to Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Test network connectivity to the Service Bus namespace
    [Tags]    servicebus    connectivity    network    access:read-only
    ${connectivity}=    RW.CLI.Run Bash File
    ...    bash_file=service_bus_connectivity_test.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${connectivity.stdout}
    ${timestamp}=    Datetime.Get Current Date
    
    # Add detailed connectivity JSON data to report
    ${connectivity_data}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_connectivity.json | jq -r 'if . == {} then "No connectivity data available" else . end'
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    RW.Core.Add Pre To Report    \n----------\nConnectivity Test Results:\n${connectivity_data.stdout}
    IF    "${connectivity.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Warnings/Errors running task.
        ...    severity=3
        ...    next_steps=Check debug logs in Report
        ...    expected=No stderr output
        ...    actual=stderr encountered
        ...    reproduce_hint=${connectivity.cmd}
        ...    details=${connectivity.stderr}
        ...    observed_at=${timestamp}
    END

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_connectivity_issues.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=Service Bus `${SB_NAMESPACE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has good connectivity
            ...    actual=Service Bus `${SB_NAMESPACE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has connectivity issues
            ...    reproduce_hint=${connectivity.cmd}
            ...    details=${item["details"]}        
            ...    observed_at=${timestamp}
        END
    END

Check Azure Monitor Alerts for Service Bus `${SB_NAMESPACE_NAME}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Check for the presence and configuration of Azure Monitor alerts
    [Tags]    servicebus    alerts    monitoring    access:read-only
    ${alerts}=    RW.CLI.Run Bash File
    ...    bash_file=service_bus_alerts_check.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${alerts.stdout}
    ${timestamp}=    Datetime.Get Current Date
    
    # Add detailed alerts JSON data to report
    ${alerts_data}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_alerts.json | jq -r 'if . == {} then "No alerts data available" else . end'
    ...    env=${env}
    ...    timeout_seconds=30
    ...    include_in_history=false
    RW.Core.Add Pre To Report    \n----------\nAlerts Configuration:\n${alerts_data.stdout}
    IF    "${alerts.stderr}" != ''
        RW.Core.Add Issue
        ...    title=Warnings/Errors running task.
        ...    severity=3
        ...    next_steps=Check debug logs in Report
        ...    expected=No stderr output
        ...    actual=stderr encountered
        ...    reproduce_hint=${alerts.cmd}
        ...    details=${alerts.stderr}
        ...    observed_at=${timestamp}
    END

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat service_bus_alerts_issues.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=Service Bus `${SB_NAMESPACE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has proper monitoring alerts
            ...    actual=Service Bus `${SB_NAMESPACE_NAME}` in resource group `${AZ_RESOURCE_GROUP}` has monitoring alert concerns
            ...    reproduce_hint=${alerts.cmd}
            ...    details=${item["details"]}        
            ...    observed_at=${timestamp}
        END
    END

*** Keywords ***
Suite Initialization
    ${AZ_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZ_RESOURCE_GROUP
    ...    type=string
    ...    description=The resource group to perform actions against.
    ...    pattern=\w*
    ${SB_NAMESPACE_NAME}=    RW.Core.Import User Variable    SB_NAMESPACE_NAME
    ...    type=string
    ...    description=The Azure Service Bus to health check. 
    ...    pattern=\w*
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    ${AZURE_RESOURCE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_RESOURCE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure Subscription ID for the resource.  
    ...    pattern=\w*
    ...    default=""
    ${ACTIVE_MESSAGE_THRESHOLD}=    RW.Core.Import User Variable    ACTIVE_MESSAGE_THRESHOLD
    ...    type=string
    ...    description=Threshold for active message count alerts (default: 1000)
    ...    pattern=\d+
    ...    default=1000
    ${DEAD_LETTER_THRESHOLD}=    RW.Core.Import User Variable    DEAD_LETTER_THRESHOLD
    ...    type=string
    ...    description=Threshold for dead letter message count alerts (default: 100)
    ...    pattern=\d+
    ...    default=100
    ${SIZE_PERCENTAGE_THRESHOLD}=    RW.Core.Import User Variable    SIZE_PERCENTAGE_THRESHOLD
    ...    type=string
    ...    description=Size percentage threshold for namespace/queue/topic alerts (default: 80)
    ...    pattern=\d+
    ...    default=80
    ${LATENCY_THRESHOLD_MS}=    RW.Core.Import User Variable    LATENCY_THRESHOLD_MS
    ...    type=string
    ...    description=Latency threshold in milliseconds for connectivity alerts (default: 100)
    ...    pattern=\d+
    ...    default=100
    Set Suite Variable    ${AZURE_RESOURCE_SUBSCRIPTION_ID}    ${AZURE_RESOURCE_SUBSCRIPTION_ID}
    Set Suite Variable    ${SB_NAMESPACE_NAME}    ${SB_NAMESPACE_NAME}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable    ${ACTIVE_MESSAGE_THRESHOLD}    ${ACTIVE_MESSAGE_THRESHOLD}
    Set Suite Variable    ${DEAD_LETTER_THRESHOLD}    ${DEAD_LETTER_THRESHOLD}
    Set Suite Variable    ${SIZE_PERCENTAGE_THRESHOLD}    ${SIZE_PERCENTAGE_THRESHOLD}
    Set Suite Variable    ${LATENCY_THRESHOLD_MS}    ${LATENCY_THRESHOLD_MS}
    Set Suite Variable
    ...    ${env}
    ...    {"SB_NAMESPACE_NAME":"${SB_NAMESPACE_NAME}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}", "AZURE_RESOURCE_SUBSCRIPTION_ID":"${AZURE_RESOURCE_SUBSCRIPTION_ID}", "ACTIVE_MESSAGE_THRESHOLD":"${ACTIVE_MESSAGE_THRESHOLD}", "DEAD_LETTER_THRESHOLD":"${DEAD_LETTER_THRESHOLD}", "SIZE_PERCENTAGE_THRESHOLD":"${SIZE_PERCENTAGE_THRESHOLD}", "LATENCY_THRESHOLD_MS":"${LATENCY_THRESHOLD_MS}"}
    # Set Azure subscription context
    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
    ...    include_in_history=false
