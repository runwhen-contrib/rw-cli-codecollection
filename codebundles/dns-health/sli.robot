*** Settings ***
Documentation       This SLI measures DNS health metrics including resolution success rates,
...                 latency measurements, DNS zone health, and external DNS resolver availability.
...                 Provides binary scoring (0/1) for each metric and calculates an overall DNS health score.
...                 Supports multiple FQDNs, DNS zones, forward lookup zones, and external resolver testing.

Metadata            Author    stewartshea
Metadata            Display Name    DNS Health Metrics
Metadata            Supports    DNS    Azure    GCP    AWS

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
    [Tags]    dns    resolution    success-rate    sli
    
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
    
    # Add public domains
    IF    '${PUBLIC_DOMAINS}' != ''
        @{public_domains}=    Split String    ${PUBLIC_DOMAINS}    ,
        FOR    ${domain}    IN    @{public_domains}
            ${domain}=    Strip String    ${domain}
            Continue For Loop If    '${domain}' == ''
            Append To List    ${all_fqdns_list}    ${domain}
        END
    END
    
    # Debug: Log what FQDNs are being tested
    ${fqdn_count}=    Get Length    ${all_fqdns_list}
    Log    DNS Resolution Test: Testing ${fqdn_count} FQDNs: ${all_fqdns_list}
    
    # Fast DNS resolution test (optimized for SLI speed)
    FOR    ${fqdn}    IN    @{all_fqdns_list}
        ${total_tests}=    Evaluate    ${total_tests} + 1
        # Use faster dig with short timeout for SLI
        ${test_cmd}=    Set Variable    timeout 5 dig +short +time=2 +tries=1 ${fqdn} @8.8.8.8 | head -1 | grep -q . && echo "SUCCESS" || echo "FAILED"
        ${rsp}=    RW.CLI.Run Cli
        ...    cmd=${test_cmd}
        ...    timeout_seconds=8
        
        # Quick success check
        ${success}=    Run Keyword And Return Status    Should Contain    ${rsp.stdout}    SUCCESS
        IF    ${success}
            ${successful_tests}=    Evaluate    ${successful_tests} + 1
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
    [Tags]    dns    latency    performance    sli
    
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
    
    # Add public domains if we have room
    IF    '${PUBLIC_DOMAINS}' != ''
        ${list_length}=    Get Length    ${all_fqdns_list}
        IF    ${list_length} < 10
            @{public_domains}=    Split String    ${PUBLIC_DOMAINS}    ,
            FOR    ${domain}    IN    @{public_domains}
                ${domain}=    Strip String    ${domain}
                Continue For Loop If    '${domain}' == ''
                Append To List    ${all_fqdns_list}    ${domain}
                ${list_length}=    Get Length    ${all_fqdns_list}
                Exit For Loop If    ${list_length} >= 10
            END
        END
    END
    
    # Fast latency test for SLI (limit to first 3 FQDNs for speed)
    ${test_limit}=    Set Variable    3
    ${fqdn_count}=    Get Length    ${all_fqdns_list}
    ${actual_limit}=    Set Variable If    ${fqdn_count} < ${test_limit}    ${fqdn_count}    ${test_limit}
    
    FOR    ${i}    IN RANGE    ${actual_limit}
        ${fqdn}=    Get From List    ${all_fqdns_list}    ${i}
        # Faster latency measurement without bc dependency
        ${latency_cmd}=    Set Variable    timeout 5 bash -c 'start=$(date +%s%N); dig +short +time=2 +tries=1 ${fqdn} @8.8.8.8 >/dev/null 2>&1; end=$(date +%s%N); echo $((($end - $start) / 1000000))'
        ${rsp}=    RW.CLI.Run Cli
        ...    cmd=${latency_cmd}
        ...    timeout_seconds=8
        
        ${stripped_stdout}=    Strip String    ${rsp.stdout}
        IF    ${rsp.returncode} == 0 and '${stripped_stdout}' != ''
            ${latency_str}=    Strip String    ${rsp.stdout}
            ${latency_valid}=    Run Keyword And Return Status    Should Match Regexp    ${latency_str}    ^[0-9]+$
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

DNS Zone Health
    [Documentation]    Measures the health of configured DNS zones (1 for healthy, 0 for unhealthy)
    [Tags]    dns    zone-health    sli
    
    ${dns_zone_health_score}=    Set Variable    ${1}
    ${total_zones}=    Set Variable    ${0}
    ${healthy_zones}=    Set Variable    ${0}
    
    # Check if we have any zones to test
    IF    '${DNS_ZONES}' == ''
        Log    No DNS zones configured for health check
        ${dns_zone_health_score}=    Set Variable    ${0}
        Set Global Variable    ${dns_zone_health_score}
        RW.Core.Push Metric    ${dns_zone_health_score}    sub_name=zone_health
        RETURN
    END
    
    @{dns_zones}=    Split String    ${DNS_ZONES}    ,
    
    FOR    ${zone}    IN    @{dns_zones}
        ${zone}=    Strip String    ${zone}
        Continue For Loop If    '${zone}' == ''
        
        Log    Checking DNS zone health: ${zone}
        ${total_zones}=    Evaluate    ${total_zones} + 1
        
        # Test zone health by attempting to resolve NS records
        ${zone_check}=    RW.CLI.Run Cli
        ...    cmd=dig NS ${zone} +short +timeout=5 | head -1
        ...    timeout_seconds=10
        
        # If we get NS records, zone is considered healthy
        ${ns_result}=    Strip String    ${zone_check.stdout}
        IF    '${ns_result}' != '' and '${zone_check.returncode}' == '0'
            ${healthy_zones}=    Evaluate    ${healthy_zones} + 1
            Log    Zone ${zone}: Healthy (NS records found)
        ELSE
            Log    Zone ${zone}: Unhealthy (no NS records or query failed)
        END
    END
    
    # Calculate binary score (1 if >=80% zones healthy, 0 otherwise)
    IF    ${total_zones} > 0
        ${health_percentage}=    Evaluate    (${healthy_zones} / ${total_zones}) * 100
        IF    ${health_percentage} >= 80
            ${dns_zone_health_score}=    Set Variable    ${1}
        ELSE
            ${dns_zone_health_score}=    Set Variable    ${0}
        END
        Log    Zone Health: ${healthy_zones}/${total_zones} zones healthy (${health_percentage}%) - Score: ${dns_zone_health_score}
    ELSE
        # DNS zones were configured but none were processed - this indicates failure
        Log    DNS zones were configured but none could be processed - Score: 0
        ${dns_zone_health_score}=    Set Variable    ${0}
    END
    
    Set Global Variable    ${dns_zone_health_score}
    RW.Core.Push Metric    ${dns_zone_health_score}    sub_name=zone_health

External DNS Resolver Availability
    [Documentation]    Measures availability of external DNS resolvers (percentage of working resolvers)
    [Tags]    dns    external    resolver    availability    sli
    
    ${total_resolvers}=    Set Variable    ${0}
    ${working_resolvers}=    Set Variable    ${0}
    
    # Fast resolver availability test (parallel testing)
    @{test_resolvers}=    Create List    8.8.8.8    1.1.1.1
    
    # Add custom resolvers if configured (limit to first 2 for SLI speed)
    IF    '${DNS_RESOLVERS}' != ''
        @{custom_resolvers}=    Split String    ${DNS_RESOLVERS}    ,
        ${custom_count}=    Get Length    ${custom_resolvers}
        ${limit}=    Set Variable If    ${custom_count} > 2    2    ${custom_count}
        FOR    ${i}    IN RANGE    ${limit}
            ${resolver}=    Get From List    ${custom_resolvers}    ${i}
            ${resolver}=    Strip String    ${resolver}
            Continue For Loop If    '${resolver}' == ''
            Append To List    ${test_resolvers}    ${resolver}
        END
    END
    
    # Test all resolvers with fast timeout
    FOR    ${resolver}    IN    @{test_resolvers}
        ${total_resolvers}=    Evaluate    ${total_resolvers} + 1
        ${test_cmd}=    Set Variable    timeout 3 dig +short +time=1 +tries=1 google.com @${resolver} | grep -q . && echo "SUCCESS" || echo "FAILED"
        ${rsp}=    RW.CLI.Run Cli
        ...    cmd=${test_cmd}
        ...    timeout_seconds=5
        
        ${success}=    Run Keyword And Return Status    Should Contain    ${rsp.stdout}    SUCCESS
        IF    ${success}
            ${working_resolvers}=    Evaluate    ${working_resolvers} + 1
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
    # Import DNS configuration variables
    ${TEST_FQDNS}=    RW.Core.Import User Variable    TEST_FQDNS
    ...    type=string
    ...    description=Important domains/services to monitor for DNS resolution (comma-separated if multiple). Example: api.mycompany.com,db.mycompany.com
    ...    pattern=^[a-zA-Z0-9.-]+(,[a-zA-Z0-9.-]+)*$
    ...    example=api.mycompany.com,db.mycompany.com
    ...    default=google.com,example.com
    
    ${FORWARD_LOOKUP_ZONES}=    RW.Core.Import User Variable    FORWARD_LOOKUP_ZONES
    ...    type=string
    ...    description=Internal company domains that forward to on-premises DNS (optional, for hybrid environments). Example: internal.company.com
    ...    pattern=^$|^[a-zA-Z0-9.-]+(,[a-zA-Z0-9.-]+)*$
    ...    example=internal.company.com
    ...    default=""
    
    ${PUBLIC_DOMAINS}=    RW.Core.Import User Variable    PUBLIC_DOMAINS
    ...    type=string
    ...    description=Your public websites to test external DNS resolution (optional). Example: mycompany.com,blog.mycompany.com
    ...    pattern=^$|^[a-zA-Z0-9.-]+(,[a-zA-Z0-9.-]+)*$
    ...    example=mycompany.com
    ...    default=""
    
    ${DNS_RESOLVERS}=    RW.Core.Import User Variable    DNS_RESOLVERS
    ...    type=string
    ...    description=Custom DNS servers to test against (comma-separated). Example: 10.0.0.4,10.0.1.4 or 8.8.8.8,1.1.1.1
    ...    pattern=^[0-9.]+(,[0-9.]+)*$
    ...    example=8.8.8.8,1.1.1.1
    ...    default=8.8.8.8,1.1.1.1
    
    ${DNS_ZONES}=    RW.Core.Import User Variable    DNS_ZONES
    ...    type=string
    ...    description=DNS zones to check health for (comma-separated). Can be private or public zones. Example: mycompany.com,internal.corp
    ...    pattern=^$|^[a-zA-Z0-9.-]+(,[a-zA-Z0-9.-]+)*$
    ...    example=mycompany.com,internal.corp
    ...    default=""
    
    # Set all suite variables
    Set Suite Variable    ${TEST_FQDNS}
    Set Suite Variable    ${FORWARD_LOOKUP_ZONES}
    Set Suite Variable    ${PUBLIC_DOMAINS}
    Set Suite Variable    ${DNS_RESOLVERS}
    Set Suite Variable    ${DNS_ZONES}
