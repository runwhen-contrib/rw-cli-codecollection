*** Settings ***
Documentation       This SLI measures DNS health metrics for Azure environments including resolution success rates,
...                 latency measurements, private DNS zone health, and external DNS resolver availability.
...                 Provides binary scoring (0/1) for each metric and calculates an overall DNS health score.
...                 Supports multiple FQDNs, private/public DNS zones, forward lookup zones, and external resolver testing.

Metadata            Author    stewartshea
Metadata            Display Name    Azure DNS Health Metrics (Multi-Zone)
Metadata            Supports    Azure    DNS    Private DNS    Public DNS    Forward Zones    VNet    SLI

Library             BuiltIn
Library             RW.Core
Library             RW.platform
Library             OperatingSystem
Library             RW.CLI
Library             Collections
Library             String

Suite Setup         Suite Initialization

*** Tasks ***
DNS Resolution Success Rate
    [Documentation]    Measures the success rate of DNS resolution across all configured FQDNs and pushes a metric (0-100)
    [Tags]    azure    dns    resolution    success-rate    sli
    
    ${total_tests}=    Set Variable    ${0}
    ${successful_tests}=    Set Variable    ${0}
    
    # Create consolidated FQDN list for testing
    ${all_fqdns_list}=    Create List
    
    # Add TEST_FQDNS
    IF    '${TEST_FQDNS}' != ''
        @{test_fqdns}=    Split String    ${TEST_FQDNS}    ,
        FOR    ${fqdn}    IN    @{test_fqdns}
            ${fqdn}=    Strip String    ${fqdn}
            Continue For Loop If    '${fqdn}' == ''
            Append To List    ${all_fqdns_list}    ${fqdn}
        END
    END
    
    # Add forward lookup zones
    IF    '${FORWARD_LOOKUP_ZONES}' != ''
        @{forward_zones}=    Split String    ${FORWARD_LOOKUP_ZONES}    ,
        FOR    ${zone}    IN    @{forward_zones}
            ${zone}=    Strip String    ${zone}
            Continue For Loop If    '${zone}' == ''
            Append To List    ${all_fqdns_list}    ${zone}
        END
    END
    
    # Add public zones
    IF    '${PUBLIC_ZONES}' != ''
        @{public_zones}=    Split String    ${PUBLIC_ZONES}    ,
        FOR    ${zone}    IN    @{public_zones}
            ${zone}=    Strip String    ${zone}
            Continue For Loop If    '${zone}' == ''
            Append To List    ${all_fqdns_list}    ${zone}
        END
    END
    
    # Debug: Log what FQDNs are being tested
    ${fqdn_count}=    Get Length    ${all_fqdns_list}
    Log    DNS Resolution Test: Testing ${fqdn_count} FQDNs: ${all_fqdns_list}
    
    # Test all FQDNs
    FOR    ${fqdn}    IN    @{all_fqdns_list}
        ${total_tests}=    Evaluate    ${total_tests} + 1
        ${test_cmd}=    Set Variable    dig +short ${fqdn} @8.8.8.8 >/dev/null 2>&1 && echo "SUCCESS" || (nslookup ${fqdn} 8.8.8.8 >/dev/null 2>&1 && echo "SUCCESS" || echo "FAILED")
        ${rsp}=    RW.CLI.Run Cli
        ...    cmd=${test_cmd}
        ...    timeout_seconds=30
        
        # Check for command execution failure first
        IF    ${rsp.returncode} != 0
            # Command failed to execute - treat as DNS failure
            Log    DNS command failed for ${fqdn}: ${rsp.stderr}
        ELSE
            ${success}=    Run Keyword And Return Status    Should Contain    ${rsp.stdout}    SUCCESS
            IF    ${success}
                ${successful_tests}=    Evaluate    ${successful_tests} + 1
            END
        END
    END
    
    # Debug: Log test results
    Log    DNS Resolution Results: ${successful_tests}/${total_tests} tests passed
    
    # Calculate binary score (1=all pass, 0=any fail)
    IF    ${total_tests} > 0
        IF    ${successful_tests} == ${total_tests}
            ${dns_resolution_score}=    Set Variable    ${1}
        ELSE
            ${dns_resolution_score}=    Set Variable    ${0}
        END
    ELSE
        # No FQDNs configured for testing - this should be an error, not success
        ${dns_resolution_score}=    Set Variable    ${0}
    END
    
    Set Global Variable    ${dns_resolution_score}
    RW.Core.Push Metric    ${dns_resolution_score}    sub_name=resolution_success

DNS Query Latency
    [Documentation]    Measures average DNS query latency in milliseconds across all configured FQDNs and pushes the metric
    [Tags]    azure    dns    latency    performance    sli
    
    ${total_latency}=    Set Variable    ${0}
    ${query_count}=    Set Variable    ${0}
    
    # Create consolidated FQDN list for latency testing (sample up to 10 FQDNs to avoid excessive testing)
    ${all_fqdns_list}=    Create List
    
    # Add TEST_FQDNS
    IF    '${TEST_FQDNS}' != ''
        @{test_fqdns}=    Split String    ${TEST_FQDNS}    ,
        FOR    ${fqdn}    IN    @{test_fqdns}
            ${fqdn}=    Strip String    ${fqdn}
            Continue For Loop If    '${fqdn}' == ''
            Append To List    ${all_fqdns_list}    ${fqdn}
            ${list_length}=    Get Length    ${all_fqdns_list}
            Exit For Loop If    ${list_length} >= 10
        END
    END
    
    # Add forward lookup zones if we have room
    IF    '${FORWARD_LOOKUP_ZONES}' != ''
        ${list_length}=    Get Length    ${all_fqdns_list}
        IF    ${list_length} < 10
            @{forward_zones}=    Split String    ${FORWARD_LOOKUP_ZONES}    ,
            FOR    ${zone}    IN    @{forward_zones}
                ${zone}=    Strip String    ${zone}
                Continue For Loop If    '${zone}' == ''
                Append To List    ${all_fqdns_list}    ${zone}
                ${list_length}=    Get Length    ${all_fqdns_list}
                Exit For Loop If    ${list_length} >= 10
            END
        END
    END
    
    # Add public zones if we have room
    IF    '${PUBLIC_ZONES}' != ''
        ${list_length}=    Get Length    ${all_fqdns_list}
        IF    ${list_length} < 10
            @{public_zones}=    Split String    ${PUBLIC_ZONES}    ,
            FOR    ${zone}    IN    @{public_zones}
                ${zone}=    Strip String    ${zone}
                Continue For Loop If    '${zone}' == ''
                Append To List    ${all_fqdns_list}    ${zone}
                ${list_length}=    Get Length    ${all_fqdns_list}
                Exit For Loop If    ${list_length} >= 10
            END
        END
    END
    
    # Test latency for all FQDNs in the list
    FOR    ${fqdn}    IN    @{all_fqdns_list}
        ${latency_cmd}=    Set Variable    start_time=$(date +%s.%N); dig +short ${fqdn} @8.8.8.8 >/dev/null 2>&1; end_time=$(date +%s.%N); echo "scale=3; ($end_time - $start_time) * 1000" | bc 2>/dev/null || echo "0"
        ${rsp}=    RW.CLI.Run Cli
        ...    cmd=${latency_cmd}
        ...    timeout_seconds=30
        
        # Check for command execution failure first
        IF    ${rsp.returncode} != 0
            # Command failed to execute - skip this measurement
            Log    DNS latency command failed for ${fqdn}: ${rsp.stderr}
        ELSE
            ${latency_str}=    Strip String    ${rsp.stdout}
            ${latency_valid}=    Run Keyword And Return Status    Should Match Regexp    ${latency_str}    ^[0-9]+\\.?[0-9]*$
            IF    ${latency_valid}
                ${latency_ms}=    Convert To Number    ${latency_str}
                ${total_latency}=    Evaluate    ${total_latency} + ${latency_ms}
                ${query_count}=    Evaluate    ${query_count} + 1
            END
        END
    END
    
    # Debug: Log latency test results
    Log    DNS Latency Results: ${query_count} successful measurements, total latency: ${total_latency}ms
    
    # Calculate binary score (1=acceptable latency, 0=high latency)
    IF    ${query_count} > 0
        ${avg_latency}=    Evaluate    ${total_latency} / ${query_count}
        # Binary score: 1 if <500ms, 0 if >=500ms
        IF    ${avg_latency} < 500
            ${dns_latency_score}=    Set Variable    ${1}
        ELSE
            ${dns_latency_score}=    Set Variable    ${0}
        END
    ELSE
        ${dns_latency_score}=    Set Variable    ${0}
    END
    
    Set Global Variable    ${dns_latency_score}
    RW.Core.Push Metric    ${dns_latency_score}    sub_name=latency_performance

Private DNS Zone Health
    [Documentation]    Measures the health of private DNS zones across multiple resource groups (1 for healthy, 0 for unhealthy)
    [Tags]    azure    dns    private-dns    zone-health    sli
    
    ${dns_zone_health_score}=    Set Variable    ${1}
    ${total_zones}=    Set Variable    ${0}
    ${healthy_zones}=    Set Variable    ${0}
    
    # Check private DNS zones in all resource groups
    @{resource_groups}=    Split String    ${RESOURCE_GROUPS}    ,
    
    FOR    ${rg}    IN    @{resource_groups}
        ${rg}=    Strip String    ${rg}
        Continue For Loop If    '${rg}' == ''
        
        # Check zone count in this resource group
        ${zone_check_cmd}=    Set Variable    az network private-dns zone list --resource-group "${rg}" --output json | jq -r 'length'
        ${rsp}=    RW.CLI.Run Cli
        ...    cmd=${zone_check_cmd}
        ...    timeout_seconds=120
        
        IF    ${rsp.returncode} == 0
            ${zone_count_str}=    Strip String    ${rsp.stdout}
            # Remove any ANSI escape codes and non-numeric characters
            ${zone_count_clean}=    Get Regexp Matches    ${zone_count_str}    [0-9]+
            IF    ${zone_count_clean}
                ${zone_count}=    Convert To Integer    ${zone_count_clean[0]}
                ${total_zones}=    Evaluate    ${total_zones} + ${zone_count}
                
                # Check for empty zones in this resource group
                IF    ${zone_count} > 0
                    ${record_check_cmd}=    Set Variable    az network private-dns zone list --resource-group "${rg}" --output json | jq -r '.[] | select(.numberOfRecordSets > 0) | .name' | wc -l
                    ${record_rsp}=    RW.CLI.Run Cli
                    ...    cmd=${record_check_cmd}
                    ...    timeout_seconds=120
                    
                    IF    ${record_rsp.returncode} == 0
                        ${healthy_zones_str}=    Strip String    ${record_rsp.stdout}
                        # Remove any ANSI escape codes and non-numeric characters
                        ${healthy_zones_clean}=    Get Regexp Matches    ${healthy_zones_str}    [0-9]+
                        IF    ${healthy_zones_clean}
                            ${rg_healthy_zones}=    Convert To Integer    ${healthy_zones_clean[0]}
                            ${healthy_zones}=    Evaluate    ${healthy_zones} + ${rg_healthy_zones}
                        END
                    END
                END
            END
        END
    END
    
    # Calculate overall health score
    IF    ${total_zones} > 0
        ${health_percentage}=    Evaluate    (${healthy_zones} * 100) / ${total_zones}
        # Consider healthy if 80% or more zones have records
        IF    ${health_percentage} >= 80
            ${dns_zone_health_score}=    Set Variable    ${1}
        ELSE
            ${dns_zone_health_score}=    Set Variable    ${0}
        END
    ELSE
        # No zones found - this indicates missing configuration or access issues
        ${dns_zone_health_score}=    Set Variable    ${0}
    END
    
    Set Global Variable    ${dns_zone_health_score}
    RW.Core.Push Metric    ${dns_zone_health_score}    sub_name=zone_health

External DNS Resolver Availability
    [Documentation]    Measures availability of external DNS resolvers (percentage of working resolvers)
    [Tags]    azure    dns    external    resolver    availability    sli
    
    ${total_resolvers}=    Set Variable    ${0}
    ${working_resolvers}=    Set Variable    ${0}
    
    # Test default resolver
    ${total_resolvers}=    Evaluate    ${total_resolvers} + 1
    ${test_cmd}=    Set Variable    dig +short google.com @8.8.8.8 >/dev/null 2>&1 && echo "SUCCESS" || (nslookup google.com 8.8.8.8 >/dev/null 2>&1 && echo "SUCCESS" || echo "FAILED")
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${test_cmd}
    ...    timeout_seconds=30
    
    # Check for command execution failure first
    IF    ${rsp.returncode} != 0
        # Command failed to execute - treat as resolver failure
        Log    Default resolver test command failed: ${rsp.stderr}
    ELSE
        ${success}=    Run Keyword And Return Status    Should Contain    ${rsp.stdout}    SUCCESS
        IF    ${success}
            ${working_resolvers}=    Evaluate    ${working_resolvers} + 1
        END
    END
    
    # Test specific DNS resolvers if configured
    IF    '${DNS_RESOLVERS}' != ''
        @{resolvers}=    Split String    ${DNS_RESOLVERS}    ,
        FOR    ${resolver}    IN    @{resolvers}
            ${resolver}=    Strip String    ${resolver}
            Continue For Loop If    '${resolver}' == ''
            
            ${total_resolvers}=    Evaluate    ${total_resolvers} + 1
            ${test_cmd}=    Set Variable    nslookup google.com ${resolver} >/dev/null 2>&1 && echo "SUCCESS" || echo "FAILED"
            ${rsp}=    RW.CLI.Run Cli
            ...    cmd=${test_cmd}
            ...    timeout_seconds=30
            
            # Check for command execution failure first
            IF    ${rsp.returncode} != 0
                # Command failed to execute - treat as resolver failure
                Log    Resolver ${resolver} test command failed: ${rsp.stderr}
            ELSE
                ${success}=    Run Keyword And Return Status    Should Contain    ${rsp.stdout}    SUCCESS
                IF    ${success}
                    ${working_resolvers}=    Evaluate    ${working_resolvers} + 1
                END
            END
        END
    ELSE
        # Test default external resolvers if no specific resolvers configured
        # Test Google DNS (8.8.8.8)
        ${total_resolvers}=    Evaluate    ${total_resolvers} + 1
        ${test_cmd}=    Set Variable    nslookup google.com 8.8.8.8 >/dev/null 2>&1 && echo "SUCCESS" || echo "FAILED"
        ${rsp}=    RW.CLI.Run Cli
        ...    cmd=${test_cmd}
        ...    timeout_seconds=30
        
        # Check for command execution failure first
        IF    ${rsp.returncode} != 0
            # Command failed to execute - treat as resolver failure
            Log    Google DNS (8.8.8.8) test command failed: ${rsp.stderr}
        ELSE
            ${success}=    Run Keyword And Return Status    Should Contain    ${rsp.stdout}    SUCCESS
            IF    ${success}
                ${working_resolvers}=    Evaluate    ${working_resolvers} + 1
            END
        END
        
        # Test Cloudflare DNS (1.1.1.1)
        ${total_resolvers}=    Evaluate    ${total_resolvers} + 1
        ${test_cmd}=    Set Variable    nslookup google.com 1.1.1.1 >/dev/null 2>&1 && echo "SUCCESS" || echo "FAILED"
        ${rsp}=    RW.CLI.Run Cli
        ...    cmd=${test_cmd}
        ...    timeout_seconds=30
        
        # Check for command execution failure first
        IF    ${rsp.returncode} != 0
            # Command failed to execute - treat as resolver failure
            Log    Cloudflare DNS (1.1.1.1) test command failed: ${rsp.stderr}
        ELSE
            ${success}=    Run Keyword And Return Status    Should Contain    ${rsp.stdout}    SUCCESS
            IF    ${success}
                ${working_resolvers}=    Evaluate    ${working_resolvers} + 1
            END
        END
    END
    
    # Calculate availability as binary score (1=all working, 0=any failing)
    IF    ${total_resolvers} > 0
        IF    ${working_resolvers} == ${total_resolvers}
            ${dns_resolver_score}=    Set Variable    ${1}
        ELSE
            ${dns_resolver_score}=    Set Variable    ${0}
        END
    ELSE
        ${dns_resolver_score}=    Set Variable    ${0}
    END
    
    Set Global Variable    ${dns_resolver_score}
    RW.Core.Push Metric    ${dns_resolver_score}    sub_name=resolver_availability

Generate DNS Health Score
    [Documentation]    Calculates the overall DNS health score as the average of all individual task scores
    [Tags]    azure    dns    aggregated    health    sli
    
    ${dns_health_score}=    Evaluate    (${dns_resolution_score} + ${dns_latency_score} + ${dns_zone_health_score} + ${dns_resolver_score}) / 4
    ${health_score}=    Convert To Number    ${dns_health_score}    2
    RW.Core.Push Metric    ${health_score}

*** Keywords ***
Suite Initialization
    # Import Azure credentials
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=.*
    
    # Import required configuration variables
    ${RESOURCE_GROUPS}=    RW.Core.Import User Variable    RESOURCE_GROUPS
    ...    type=string
    ...    description=Comma-separated list of Azure resource groups containing DNS zones and VNets
    ...    pattern=.*
    ...    example=my-plink-rg,production-rg,network-rg
    
    ${TEST_FQDNS}=    RW.Core.Import User Variable    TEST_FQDNS
    ...    type=string
    ...    description=Comma-separated list of FQDNs to test for DNS resolution
    ...    pattern=.*
    ...    example=myapp.privatelink.database.windows.net,myapi.privatelink.azurewebsites.net
    
    # Import optional DNS testing configuration
    ${FORWARD_LOOKUP_ZONES}=    RW.Core.Import User Variable    FORWARD_LOOKUP_ZONES
    ...    type=string
    ...    description=Comma-separated list of forward lookup zones to test (optional)
    ...    pattern=.*
    ...    example=internal.company.com,corp.local
    ...    default=""
    
    ${PUBLIC_ZONES}=    RW.Core.Import User Variable    PUBLIC_ZONES
    ...    type=string
    ...    description=Comma-separated list of public DNS zones to test (optional)
    ...    pattern=.*
    ...    example=example.com,mycompany.com
    ...    default=""
    
    ${DNS_RESOLVERS}=    RW.Core.Import User Variable    DNS_RESOLVERS
    ...    type=string
    ...    description=Comma-separated list of specific DNS resolvers to test against (optional)
    ...    pattern=.*
    ...    example=8.8.8.8,1.1.1.1,10.0.0.4
    ...    default=""
    
    # Set all suite variables
    Set Suite Variable    ${azure_credentials}
    Set Suite Variable    ${RESOURCE_GROUPS}
    Set Suite Variable    ${TEST_FQDNS}
    Set Suite Variable    ${FORWARD_LOOKUP_ZONES}
    Set Suite Variable    ${PUBLIC_ZONES}
    Set Suite Variable    ${DNS_RESOLVERS}
