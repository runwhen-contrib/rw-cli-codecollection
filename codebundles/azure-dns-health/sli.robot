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

Private DNS Zone Health
    [Documentation]    Measures the health of private DNS zones across multiple resource groups (1 for healthy, 0 for unhealthy)
    [Tags]    azure    dns    private-dns    zone-health    sli
    
    ${dns_zone_health_score}=    Set Variable    ${1}
    ${total_zones}=    Set Variable    ${0}
    ${healthy_zones}=    Set Variable    ${0}
    
    # Fast private DNS zone health check (single call per RG)
    @{resource_groups}=    Split String    ${RESOURCE_GROUPS}    ,
    
    FOR    ${rg}    IN    @{resource_groups}
        ${rg}=    Strip String    ${rg}
        Continue For Loop If    '${rg}' == ''
        
        # Get total zone count
        ${total_cmd}=    Set Variable    timeout 15 az network private-dns zone list --resource-group "${rg}" --query "length(@)" --output tsv 2>/dev/null || echo "0"
        ${total_rsp}=    RW.CLI.Run Cli
        ...    cmd=${total_cmd}
        ...    timeout_seconds=20
        
        # Get healthy zone count (zones with records)
        ${healthy_cmd}=    Set Variable    timeout 15 az network private-dns zone list --resource-group "${rg}" --query "[?numberOfRecordSets > \`0\`] | length(@)" --output tsv 2>/dev/null || echo "0"
        ${healthy_rsp}=    RW.CLI.Run Cli
        ...    cmd=${healthy_cmd}
        ...    timeout_seconds=20
        
        # Process results if both commands succeeded
        IF    ${total_rsp.returncode} == 0 and ${healthy_rsp.returncode} == 0
            ${rg_total_str}=    Strip String    ${total_rsp.stdout}
            ${rg_healthy_str}=    Strip String    ${healthy_rsp.stdout}
            
            # Only convert if they're actually numbers
            ${is_total_numeric}=    Run Keyword And Return Status    Should Match Regexp    ${rg_total_str}    ^\\d+$
            ${is_healthy_numeric}=    Run Keyword And Return Status    Should Match Regexp    ${rg_healthy_str}    ^\\d+$
            
            IF    ${is_total_numeric} and ${is_healthy_numeric}
                ${rg_total}=    Convert To Integer    ${rg_total_str}
                ${rg_healthy}=    Convert To Integer    ${rg_healthy_str}
                ${total_zones}=    Evaluate    ${total_zones} + ${rg_total}
                ${healthy_zones}=    Evaluate    ${healthy_zones} + ${rg_healthy}
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
    # Import Azure credentials
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=.*
    
    # Import auto-discovery configuration
    ${AUTO_DISCOVER_DNS_RESOURCES}=    RW.Core.Import User Variable    AUTO_DISCOVER_DNS_RESOURCES
    ...    type=string
    ...    description=Enable automatic discovery of Azure DNS resources (true/false). When enabled, reduces required configuration to just Azure credentials.
    ...    pattern=^(true|false)$
    ...    example=true
    ...    default=false
    
    ${AZURE_RESOURCE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_RESOURCE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=Azure subscription ID for auto-discovery and resource access. Leave empty to use current Azure CLI subscription.
    ...    pattern=^$|^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$
    ...    example=2a0cf760-baef-4446-b75c-75c4f8a6267f
    ...    default=""
    
    # Import configuration variables (optional when auto-discovery is enabled)
    ${RESOURCE_GROUPS}=    RW.Core.Import User Variable    RESOURCE_GROUPS
    ...    type=string
    ...    description=Azure resource groups containing your DNS zones (comma-separated if multiple). Leave empty to use auto-discovery. Example: production-rg or network-rg,app-rg
    ...    pattern=^$|^[a-zA-Z0-9._-]+(,[a-zA-Z0-9._-]+)*$
    ...    example=production-rg
    ...    default=""
    
    ${TEST_FQDNS}=    RW.Core.Import User Variable    TEST_FQDNS
    ...    type=string
    ...    description=Important domains/services to monitor for DNS resolution (comma-separated if multiple). Leave empty to use auto-discovery. Example: myapp.database.windows.net or api.mycompany.com,db.mycompany.com
    ...    pattern=^$|^[a-zA-Z0-9.-]+(,[a-zA-Z0-9.-]+)*$
    ...    example=myapp.database.windows.net
    ...    default=""
    
    # Import optional DNS testing configuration
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
    ...    description=Custom DNS servers to test against (optional, uses Google/Cloudflare if empty). Example: 10.0.0.4,10.0.1.4
    ...    pattern=^$|^[0-9.]+(,[0-9.]+)*$
    ...    example=10.0.0.4
    ...    default=""
    
    # Lightweight auto-discovery for SLI (cache-first approach)
    IF    "${AUTO_DISCOVER_DNS_RESOURCES}" == "true"
        Log    Auto-discovery enabled for SLI. Checking for cached results...
        
        # Check if recent discovery results exist (avoid expensive re-discovery)
        ${discovery_exists}=    Run Keyword And Return Status    File Should Exist    ${CURDIR}/azure_dns_discovery.json
        ${cache_valid}=    Set Variable    ${False}
        
        IF    ${discovery_exists}
            # Check if cache is recent (less than 1 hour old)
            ${cache_check}=    RW.CLI.Run Cli
            ...    cmd=find ${CURDIR}/azure_dns_discovery.json -mmin -60 | wc -l
            ...    timeout_seconds=5
            
            ${cache_check_output}=    Strip String    ${cache_check.stdout}
            ${cache_valid}=    Run Keyword And Return Status    Should Be Equal As Strings    ${cache_check_output}    1
        END
        
        # Only run discovery if no valid cache exists
        IF    not ${cache_valid}
            Log    No valid cache found. Running lightweight discovery for SLI...
            
            # Run discovery script (same as runbook but with shorter timeout for SLI)
            ${discovery_result}=    RW.CLI.Run Cli
            ...    cmd=cd ${CURDIR} && AZURE_RESOURCE_SUBSCRIPTION_ID="${AZURE_RESOURCE_SUBSCRIPTION_ID}" bash azure_dns_auto_discovery.sh
            ...    timeout_seconds=60
            
            ${discovery_exists}=    Run Keyword And Return Status    File Should Exist    ${CURDIR}/azure_dns_discovery.json
        END
        
        # Parse results efficiently
        IF    ${discovery_exists}
            ${auto_resource_groups_result}=    RW.CLI.Run Cli
            ...    cmd=cat ${CURDIR}/azure_dns_discovery.json | jq -r '.discovery.resource_groups | join(",") // ""'
            ...    timeout_seconds=10
            ${auto_resource_groups}=    Strip String    ${auto_resource_groups_result.stdout}
            
            ${auto_test_fqdns_result}=    RW.CLI.Run Cli
            ...    cmd=cat ${CURDIR}/azure_dns_discovery.json | jq -r '.discovery.suggested_test_fqdns | join(",") // ""'
            ...    timeout_seconds=10
            ${auto_test_fqdns}=    Strip String    ${auto_test_fqdns_result.stdout}
            
            ${auto_forward_zones_result}=    RW.CLI.Run Cli
            ...    cmd=cat ${CURDIR}/azure_dns_discovery.json | jq -r '.discovery.forward_lookup_zones | join(",") // ""'
            ...    timeout_seconds=10
            ${auto_forward_zones}=    Strip String    ${auto_forward_zones_result.stdout}
            
            ${auto_public_domains_result}=    RW.CLI.Run Cli
            ...    cmd=cat ${CURDIR}/azure_dns_discovery.json | jq -r '.discovery.public_dns_zones | join(",") // ""'
            ...    timeout_seconds=10
            ${auto_public_domains}=    Strip String    ${auto_public_domains_result.stdout}
            
            ${auto_dns_resolvers_result}=    RW.CLI.Run Cli
            ...    cmd=cat ${CURDIR}/azure_dns_discovery.json | jq -r '.discovery.dns_resolvers | join(",") // ""'
            ...    timeout_seconds=10
            ${auto_dns_resolvers}=    Strip String    ${auto_dns_resolvers_result.stdout}
            
            # When auto-discovery is enabled, always use discovered values (same as runbook)
            ${RESOURCE_GROUPS}=    Set Variable    ${auto_resource_groups}
            ${TEST_FQDNS}=    Set Variable    ${auto_test_fqdns}
            ${FORWARD_LOOKUP_ZONES}=    Set Variable    ${auto_forward_zones}
            ${PUBLIC_DOMAINS}=    Set Variable    ${auto_public_domains}
            ${DNS_RESOLVERS}=    Set Variable    ${auto_dns_resolvers}
            
            ${cache_status}=    Set Variable If    ${cache_valid}    cached    fresh
            Log    SLI auto-discovery completed using ${cache_status} results.
        ELSE
            Log    Auto-discovery failed for SLI. Using manual configuration.
        END
    END
    
    # Set all suite variables
    Set Suite Variable    ${azure_credentials}
    Set Suite Variable    ${AUTO_DISCOVER_DNS_RESOURCES}
    Set Suite Variable    ${AZURE_RESOURCE_SUBSCRIPTION_ID}
    Set Suite Variable    ${RESOURCE_GROUPS}
    Set Suite Variable    ${TEST_FQDNS}
    Set Suite Variable    ${FORWARD_LOOKUP_ZONES}
    Set Suite Variable    ${PUBLIC_DOMAINS}
    Set Suite Variable    ${DNS_RESOLVERS}
