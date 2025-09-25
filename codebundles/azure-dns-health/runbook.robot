*** Settings ***
Documentation       This taskset performs comprehensive DNS health monitoring and validation tasks for Azure environments.
...                 Includes private/public DNS zone record validation, broken DNS resolution detection,
...                 forward lookup zone testing, external resolution validation, and Express Route latency monitoring.
...                 Provides detailed issue reporting with severity levels and actionable next steps.
...                 Supports multiple FQDNs, resource groups, zones, and both Azure-specific and generic DNS monitoring scenarios.

Metadata            Author    stewartshea
Metadata            Display Name    Azure DNS Health & Monitoring (Multi-Zone)
Metadata            Supports    Azure    DNS    Private DNS    Public DNS    Forward Zones    Express Route

Library             BuiltIn
Library             RW.Core
Library             RW.platform
Library             OperatingSystem
Library             RW.CLI
Library             Collections
Library             String

Suite Setup         Suite Initialization

*** Tasks ***
Check Private DNS Zone Records
    [Documentation]    Verifies record counts and integrity for private DNS zones in the specified resource group(s)
    [Tags]    access:read-only    azure    dns    private-dns    zone-records
    
    # Process multiple resource groups if specified
    @{resource_groups}=    Split String    ${RESOURCE_GROUPS}    ,
    
    FOR    ${rg}    IN    @{resource_groups}
        ${rg}=    Strip String    ${rg}
        Continue For Loop If    '${rg}' == ''
        
        ${zone_check_cmd}=    Set Variable    az network private-dns zone list --resource-group "${rg}" --output json | jq -r '.[] | "Zone: " + .name + " Records: " + (.numberOfRecordSets | tostring) + " RG: '${rg}'"'
        
        ${rsp}=    RW.CLI.Run Cli
        ...    cmd=${zone_check_cmd}
        ...    timeout_seconds=300
        
        RW.Core.Add Pre To Report    === DNS Zone Health Check ===
        RW.Core.Add Pre To Report    Resource Group: ${rg}
        RW.Core.Add Pre To Report    Zone Information: ${rsp.stdout}
        
        # Check for empty zones or missing records
        ${empty_zones}=    Run Keyword And Return Status    Should Contain    ${rsp.stdout}    Records: 0
        IF    ${empty_zones}
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=All private DNS zones should contain records
            ...    actual=Found private DNS zones with no records in resource group ${rg}
            ...    title=Empty Private DNS Zones Detected in ${rg}
            ...    reproduce_hint=Check private DNS zone configuration in resource group ${rg}
            ...    details=Empty zones found in ${rg}: ${rsp.stdout}
            ...    next_steps=1. Review private DNS zone configuration in ${rg}\n2. Verify DNS records are properly configured\n3. Check if zones should be deleted or populated with records
        END
        
        IF    ${rsp.returncode} != 0
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Private DNS zone check should complete successfully
            ...    actual=Private DNS zone check failed for resource group ${rg} with return code ${rsp.returncode}
            ...    title=Private DNS Zone Check Failed for ${rg}
            ...    reproduce_hint=Verify Azure credentials and resource group access for ${rg}
            ...    details=Command failed: ${zone_check_cmd}\nError: ${rsp.stderr}
            ...    next_steps=1. Verify Azure CLI authentication\n2. Check resource group permissions for ${rg}\n3. Validate resource group name: ${rg}
        END
    END
    
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    === Task Summary ===
    RW.Core.Add Pre To Report    Private DNS zone health check completed for all specified resource groups.
    RW.Core.Add Pre To Report    Commands Used: ${history}

Check Public DNS Zone Records
    [Documentation]    Verifies record counts and integrity for public DNS zones in the specified resource group(s)
    [Tags]    access:read-only    azure    dns    public-dns    zone-records
    
    # Process multiple resource groups if specified
    @{resource_groups}=    Split String    ${RESOURCE_GROUPS}    ,
    
    FOR    ${rg}    IN    @{resource_groups}
        ${rg}=    Strip String    ${rg}
        Continue For Loop If    '${rg}' == ''
        
        ${zone_check_cmd}=    Set Variable    az network dns zone list --resource-group "${rg}" --output json | jq -r '.[] | "Zone: " + .name + " Records: " + (.numberOfRecordSets | tostring) + " RG: '${rg}'"'
        
        ${rsp}=    RW.CLI.Run Cli
        ...    cmd=${zone_check_cmd}
        ...    timeout_seconds=300
        
        RW.Core.Add Pre To Report    === Public DNS Zone Health Check ===
        RW.Core.Add Pre To Report    Resource Group: ${rg}
        RW.Core.Add Pre To Report    Zone Information: ${rsp.stdout}
        ${has_stderr}=    Run Keyword And Return Status    Should Not Be Empty    ${rsp.stderr}
        IF    ${has_stderr}
            RW.Core.Add Pre To Report    Warnings: ${rsp.stderr}
        END
        
        # Check for zones with minimal records (less than expected minimum)
        ${minimal_records_pattern}=    Set Variable    Records: [0-2]\\b
        ${minimal_zones}=    Get Regexp Matches    ${rsp.stdout}    ${minimal_records_pattern}
        ${minimal_count}=    Get Length    ${minimal_zones}
        IF    ${minimal_count} > 0
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=Public DNS zones should have adequate record sets
            ...    actual=Found ${minimal_count} public DNS zones with minimal records in resource group ${rg}
            ...    title=Public DNS Zones with Minimal Records in ${rg}
            ...    reproduce_hint=Check public DNS zone configuration in resource group ${rg}
            ...    details=Zones with minimal records in ${rg}: ${rsp.stdout}
            ...    next_steps=1. Review public DNS zone configuration in ${rg}\n2. Verify required DNS records are configured\n3. Check if additional records need to be added
        END
        
        IF    ${rsp.returncode} != 0
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Public DNS zone check should complete successfully
            ...    actual=Public DNS zone check failed for resource group ${rg} with return code ${rsp.returncode}
            ...    title=Public DNS Zone Check Failed for ${rg}
            ...    reproduce_hint=Verify Azure credentials and resource group access for ${rg}
            ...    details=Command failed: ${zone_check_cmd}\nError: ${rsp.stderr}
            ...    next_steps=1. Verify Azure CLI authentication\n2. Check resource group permissions for ${rg}\n3. Validate resource group name: ${rg}
        END
    END
    
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}


Detect Broken Record Resolution
    [Documentation]    Implements repeated pull/flush/pull DNS checks for multiple FQDNs to detect failures before TTL expiry
    [Tags]    access:read-only    azure    dns    resolution    consistency
    
    # Test all configured FQDNs with cache flush
    @{broken_resolution_fqdns}=    Split String    ${TEST_FQDNS}    ,
    
    FOR    ${fqdn}    IN    @{broken_resolution_fqdns}
        ${fqdn}=    Strip String    ${fqdn}
        Continue For Loop If    '${fqdn}' == ''
        
        # Use custom DNS resolver if configured, otherwise default to Google DNS
        IF    '${DNS_RESOLVERS}' != ''
            @{dns_resolver_list}=    Split String    ${DNS_RESOLVERS}    ,
            ${first_resolver}=    Get From List    ${dns_resolver_list}    0
            ${resolver}=    Strip String    ${first_resolver}
        ELSE
            ${resolver}=    Set Variable    8.8.8.8
        END
        ${dns_test}=    Set Variable    for i in {1..3}; do echo "=== Test $i for ${fqdn} ==="; dig +nocmd +noall +answer ${fqdn} @${resolver} || nslookup ${fqdn} ${resolver}; sleep 2; done
        
        ${rsp}=    RW.CLI.Run Cli
        ...    cmd=${dns_test}
        ...    timeout_seconds=120
        
        RW.Core.Add Pre To Report    === DNS Resolution Test ===
        RW.Core.Add Pre To Report    Testing Domain: ${fqdn}
        RW.Core.Add Pre To Report    Test Results: ${rsp.stdout}
        
        # Check for resolution failures
        ${failures}=    Get Regexp Matches    ${rsp.stdout}    can't find.*NXDOMAIN|server can't find
        ${failure_count}=    Get Length    ${failures}
        IF    ${failure_count} > 0
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=FQDN should resolve consistently across multiple attempts
            ...    actual=FQDN resolution failed ${failure_count} times for ${fqdn}
            ...    title=DNS Resolution Inconsistency for ${fqdn}
            ...    reproduce_hint=Test DNS resolution for ${fqdn} multiple times with cache flush
            ...    details=FQDN: ${fqdn}\nFailures: ${failure_count}\nDetails: ${rsp.stdout}
            ...    next_steps=1. Check DNS configuration for ${fqdn}\n2. Verify private endpoint configuration if applicable\n3. Review DNS zone records\n4. Check DNS server health\n5. Verify TTL settings
        END
        
        # Check for timeout issues
        ${timeouts}=    Get Regexp Matches    ${rsp.stdout}    connection timed out|no response
        ${timeout_count}=    Get Length    ${timeouts}
        IF    ${timeout_count} > 0
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=DNS queries should complete without timeouts
            ...    actual=DNS queries timed out ${timeout_count} times for ${fqdn}
            ...    title=DNS Query Timeouts for ${fqdn}
            ...    reproduce_hint=Test DNS resolution for ${fqdn} and check network connectivity
            ...    details=FQDN: ${fqdn}\nTimeouts: ${timeout_count}\nDetails: ${rsp.stdout}
            ...    next_steps=1. Check network connectivity to DNS servers\n2. Verify DNS server responsiveness\n3. Check firewall rules\n4. Review DNS forwarder configuration
        END
    END
    
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Test Forward Lookup Zones
    [Documentation]    Tests forward lookup zones and conditional forwarders for proper resolution
    [Tags]    access:read-only    azure    dns    forward-lookup    conditional-forwarders
    
    # Test forward lookup zones if specified
    IF    '${FORWARD_LOOKUP_ZONES}' != ''
        @{forward_zones}=    Split String    ${FORWARD_LOOKUP_ZONES}    ,
        
        FOR    ${zone}    IN    @{forward_zones}
            ${zone}=    Strip String    ${zone}
            Continue For Loop If    '${zone}' == ''
            
            # Test resolution for the zone itself
            ${zone_test_cmd}=    Set Variable    nslookup ${zone} && echo "Forward Zone ${zone}: SUCCESS" || echo "Forward Zone ${zone}: FAILED"
            
            ${zone_rsp}=    RW.CLI.Run Cli
            ...    cmd=${zone_test_cmd}
            ...    timeout_seconds=60
            
            RW.Core.Add Pre To Report    Forward Lookup Zone Test: ${zone}
            RW.Core.Add Pre To Report    Command: ${zone_test_cmd}
            RW.Core.Add Pre To Report    Output: ${zone_rsp.stdout}
            
            ${zone_failed}=    Run Keyword And Return Status    Should Contain    ${zone_rsp.stdout}    FAILED
            IF    ${zone_failed}
                RW.Core.Add Issue
                ...    severity=2
                ...    expected=Forward lookup zone should resolve properly
                ...    actual=Forward lookup zone ${zone} resolution failed
                ...    title=Forward Lookup Zone Resolution Failure: ${zone}
                ...    reproduce_hint=Test DNS resolution for forward lookup zone ${zone}
                ...    details=Zone: ${zone}\nResult: ${zone_rsp.stdout}
                ...    next_steps=1. Check conditional forwarder configuration for ${zone}\n2. Verify upstream DNS server connectivity\n3. Review DNS forwarder rules\n4. Check network routing to target DNS servers
            END
            
            # Test a common subdomain if specified
            IF    '${FORWARD_ZONE_TEST_SUBDOMAINS}' != ''
                @{subdomains}=    Split String    ${FORWARD_ZONE_TEST_SUBDOMAINS}    ,
                FOR    ${subdomain}    IN    @{subdomains}
                    ${subdomain}=    Strip String    ${subdomain}
                    Continue For Loop If    '${subdomain}' == ''
                    
                    ${full_fqdn}=    Set Variable    ${subdomain}.${zone}
                    ${subdomain_test_cmd}=    Set Variable    nslookup ${full_fqdn} && echo "Subdomain ${full_fqdn}: SUCCESS" || echo "Subdomain ${full_fqdn}: FAILED"
                    
                    ${subdomain_rsp}=    RW.CLI.Run Cli
                    ...    cmd=${subdomain_test_cmd}
                    ...    timeout_seconds=60
                    
                    RW.Core.Add Pre To Report    Forward Zone Subdomain Test: ${full_fqdn}
                    RW.Core.Add Pre To Report    Output: ${subdomain_rsp.stdout}
                    
                    ${subdomain_failed}=    Run Keyword And Return Status    Should Contain    ${subdomain_rsp.stdout}    FAILED
                    IF    ${subdomain_failed}
                        RW.Core.Add Issue
                        ...    severity=1
                        ...    expected=Forward lookup zone subdomains should resolve properly
                        ...    actual=Forward lookup zone subdomain ${full_fqdn} resolution failed
                        ...    title=Forward Zone Subdomain Resolution Failure: ${full_fqdn}
                        ...    reproduce_hint=Test DNS resolution for ${full_fqdn}
                        ...    details=FQDN: ${full_fqdn}\nZone: ${zone}\nResult: ${subdomain_rsp.stdout}
                        ...    next_steps=1. Check if subdomain exists in forward zone\n2. Verify conditional forwarder for ${zone}\n3. Test direct query to authoritative server
                    END
                END
            END
        END
    END
    
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}


External Resolution Validation
    [Documentation]    Tests resolution of multiple public and private hosted domains through multiple resolvers, testing upstream forwarding
    [Tags]    access:read-only    azure    dns    external    public    resolvers
    
     # Test public domain resolution through multiple resolvers
     IF    '${PUBLIC_DOMAINS}' != '' and '${PUBLIC_DOMAINS}' != '""'
         @{public_domains}=    Split String    ${PUBLIC_DOMAINS}    ,
        
        FOR    ${domain}    IN    @{public_domains}
            ${domain}=    Strip String    ${domain}
            Continue For Loop If    '${domain}' == ''
            
            # Test with default resolver
            ${default_test}=    Set Variable    nslookup ${domain}
            ${default_rsp}=    RW.CLI.Run Cli
            ...    cmd=${default_test}
            ...    timeout_seconds=60
            
            # Determine which resolvers to test
            @{test_resolvers}=    Create List    8.8.8.8    1.1.1.1
            @{resolver_names}=    Create List    Google DNS (8.8.8.8)    Cloudflare DNS (1.1.1.1)
            
            IF    '${DNS_RESOLVERS}' != ''
                @{custom_resolvers}=    Split String    ${DNS_RESOLVERS}    ,
                @{test_resolvers}=    Create List
                @{resolver_names}=    Create List
                FOR    ${resolver}    IN    @{custom_resolvers}
                    ${resolver}=    Strip String    ${resolver}
                    Continue For Loop If    '${resolver}' == ''
                    Append To List    ${test_resolvers}    ${resolver}
                    Append To List    ${resolver_names}    Custom DNS (${resolver})
                END
            END
            
            # Test with each resolver
            @{resolver_results}=    Create List
            ${resolver_count}=    Get Length    ${test_resolvers}
            FOR    ${i}    IN RANGE    ${resolver_count}
                ${resolver}=    Get From List    ${test_resolvers}    ${i}
                ${resolver_name}=    Get From List    ${resolver_names}    ${i}
                ${resolver_test}=    Set Variable    nslookup ${domain} ${resolver}
                ${resolver_rsp}=    RW.CLI.Run Cli
                ...    cmd=${resolver_test}
                ...    timeout_seconds=60
                Append To List    ${resolver_results}    ${resolver_rsp.stdout}
                RW.Core.Add Pre To Report    ${resolver_name}: ${resolver_rsp.stdout}
            END
            
            RW.Core.Add Pre To Report    External DNS Resolution Validation - Domain: ${domain}
            RW.Core.Add Pre To Report    Default Resolver: ${default_rsp.stdout}
            
            # Check for resolution inconsistencies
            ${default_failed}=    Run Keyword And Return Status    Should Contain    ${default_rsp.stdout}    can't find
            ${failed_count}=    Set Variable    ${default_failed}
            ${resolver_results_count}=    Get Length    ${resolver_results}
            ${total_resolvers}=    Evaluate    ${resolver_results_count} + 1
            
            # Build details string for issue reporting
            ${details}=    Set Variable    Domain: ${domain}\nDefault: ${default_rsp.stdout}
            FOR    ${i}    IN RANGE    ${resolver_results_count}
                ${result}=    Get From List    ${resolver_results}    ${i}
                ${resolver_name}=    Get From List    ${resolver_names}    ${i}
                ${resolver_failed}=    Run Keyword And Return Status    Should Contain    ${result}    can't find
                ${failed_count}=    Evaluate    ${failed_count} + ${resolver_failed}
                ${details}=    Set Variable    ${details}\n${resolver_name}: ${result}
            END
            
            IF    ${failed_count} > 0
                RW.Core.Add Issue
                ...    severity=2
                ...    expected=Public domain should resolve through all DNS resolvers
                ...    actual=Public domain ${domain} resolution failed through ${failed_count} resolver(s)
                ...    title=External DNS Resolution Inconsistency for ${domain}
                ...    reproduce_hint=Test DNS resolution for ${domain} through multiple resolvers
                ...    details=${details}
                ...    next_steps=1. Check DNS forwarder configuration\n2. Verify upstream DNS connectivity\n3. Review firewall rules for DNS traffic\n4. Test network connectivity to external resolvers
            END
            
            # Check for complete resolution failures across all resolvers
            IF    ${failed_count} == ${total_resolvers}
                RW.Core.Add Issue
                ...    severity=3
                ...    expected=Public domain should resolve through at least one resolver
                ...    actual=Public domain ${domain} failed to resolve through all resolvers
                ...    title=Complete DNS Resolution Failure for ${domain}
                ...    reproduce_hint=Verify domain ${domain} exists and is properly configured
                ...    details=Domain: ${domain} failed resolution through all tested resolvers
                ...    next_steps=1. Verify domain registration and DNS configuration\n2. Check if domain exists\n3. Test from different network location\n4. Contact domain administrator
            END
        END
    END
    
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Express Route Latency and Saturation Check
    [Documentation]    Alerts if DNS queries through multiple forwarded zones show high latency or packet drops, indicating possible route congestion
    [Tags]    access:read-only    azure    dns    express-route    latency    performance
    
    # Test DNS query latency through Express Route for multiple zones
    IF    '${EXPRESS_ROUTE_DNS_ZONES}' != ''
        @{express_route_zones}=    Split String    ${EXPRESS_ROUTE_DNS_ZONES}    ,
        
        FOR    ${zone}    IN    @{express_route_zones}
            ${zone}=    Strip String    ${zone}
            Continue For Loop If    '${zone}' == ''
            
            # Perform multiple DNS queries to measure latency
            ${latency_test}=    Set Variable    for i in {1..10}; do echo "Query $i for ${zone}:"; (time nslookup test.${zone} 2>&1) 2>&1 | grep -E "real|user|sys"; sleep 1; done
            
            ${latency_rsp}=    RW.CLI.Run Cli
            ...    cmd=${latency_test}
            ...    timeout_seconds=180
            
            RW.Core.Add Pre To Report    Express Route DNS Latency Check - Zone: ${zone}
            RW.Core.Add Pre To Report    Latency Results: ${latency_rsp.stdout}
            
            # Check if no timing data was captured (domain doesn't exist)
            ${no_timing_data}=    Run Keyword And Return Status    Should Be Empty    ${latency_rsp.stdout}
            IF    ${no_timing_data}
                RW.Core.Add Issue
                ...    severity=1
                ...    expected=Express Route DNS latency data should be available for zone ${zone}
                ...    actual=No latency data captured for zone ${zone} - domain test.${zone} may not exist
                ...    title=Express Route DNS Latency Data Unavailable for ${zone}
                ...    reproduce_hint=Test DNS resolution for test.${zone} to verify domain existence
                ...    details=Zone: ${zone}\nTest Domain: test.${zone}\nReason: Domain may not exist or DNS resolution failed\nLatency Results: ${latency_rsp.stdout}
                ...    next_steps=1. Verify that test.${zone} domain exists\n2. Check DNS configuration for ${zone}\n3. Ensure proper DNS forwarder setup\n4. Test with a valid subdomain
            END
            
            # Extract latency values and check for high latency
            ${high_latency_pattern}=    Set Variable    real\\s+0m([5-9]|[1-9][0-9])\\.[0-9]+s
            ${high_latency_matches}=    Get Regexp Matches    ${latency_rsp.stdout}    ${high_latency_pattern}
            ${high_latency_count}=    Get Length    ${high_latency_matches}
            
            IF    ${high_latency_count} > 2
                RW.Core.Add Issue
                ...    severity=2
                ...    expected=DNS queries through Express Route should have low latency (<5 seconds)
                ...    actual=Found ${high_latency_count} DNS queries with high latency (>5 seconds) for zone ${zone}
                ...    title=High DNS Latency Through Express Route for ${zone}
                ...    reproduce_hint=Test DNS query latency for zone ${zone}
                ...    details=Zone: ${zone}\nHigh latency queries: ${high_latency_count}\nResults: ${latency_rsp.stdout}
                ...    next_steps=1. Check Express Route connectivity\n2. Review DNS forwarder performance for ${zone}\n3. Monitor Express Route bandwidth utilization\n4. Check for network congestion\n5. Verify DNS server performance
            END
            
            # Check for complete query failures
            ${query_failures}=    Get Regexp Matches    ${latency_rsp.stdout}    can't find|server can't find|NXDOMAIN
            ${failure_count}=    Get Length    ${query_failures}
            IF    ${failure_count} > 3
                RW.Core.Add Issue
                ...    severity=3
                ...    expected=DNS queries through Express Route should resolve successfully
                ...    actual=Found ${failure_count} failed DNS queries for zone ${zone}
                ...    title=DNS Query Failures Through Express Route for ${zone}
                ...    reproduce_hint=Test DNS resolution for zone ${zone} through Express Route
                ...    details=Zone: ${zone}\nFailed queries: ${failure_count}\nResults: ${latency_rsp.stdout}
                ...    next_steps=1. Check Express Route DNS forwarder configuration\n2. Verify zone ${zone} exists and is reachable\n3. Test direct connectivity to authoritative servers\n4. Review conditional forwarder rules
            END
        END
    END
    
    
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

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
     ...    description=Enable smart Azure DNS autodiscovery (true/false). Analyzes actual Azure DNS configuration instead of using generic defaults.
     ...    pattern=^(true|false)$
     ...    example=true
     ...    default=true
     
     ${AZURE_RESOURCE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_RESOURCE_SUBSCRIPTION_ID
     ...    type=string
     ...    description=Azure subscription ID for autodiscovery. Leave empty to use current Azure CLI subscription.
     ...    pattern=^$|^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$
     ...    example=2a0cf760-baef-4446-b75c-75c4f8a6267f
     ...    default=""
     
     # Import configuration variables (optional when autodiscovery is enabled)
     ${RESOURCE_GROUPS}=    RW.Core.Import User Variable    RESOURCE_GROUPS
     ...    type=string
     ...    description=Azure resource groups containing your DNS zones (comma-separated if multiple). Leave empty for autodiscovery. Example: production-rg or network-rg,app-rg
     ...    pattern=^$|^[a-zA-Z0-9._-]+(,[a-zA-Z0-9._-]+)*$
     ...    example=production-rg
     ...    default=""
    
     ${TEST_FQDNS}=    RW.Core.Import User Variable    TEST_FQDNS
     ...    type=string
     ...    description=Important domains/services to monitor for DNS resolution (comma-separated if multiple). Leave empty for autodiscovery. Example: myapp.database.windows.net or api.mycompany.com,db.mycompany.com
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
    
    ${EXPRESS_ROUTE_DNS_ZONES}=    RW.Core.Import User Variable    EXPRESS_ROUTE_DNS_ZONES
    ...    type=string
    ...    description=Domains accessed through Express Route for latency monitoring (optional). Example: internal.company.com
    ...    pattern=^$|^[a-zA-Z0-9.-]+(,[a-zA-Z0-9.-]+)*$
    ...    example=internal.company.com
    ...    default=""
    
    ${FORWARD_ZONE_TEST_SUBDOMAINS}=    RW.Core.Import User Variable    FORWARD_ZONE_TEST_SUBDOMAINS
    ...    type=string
    ...    description=Specific servers to test in forward lookup zones (optional). Example: dc01,mail,web
    ...    pattern=^$|^[a-zA-Z0-9-]+(,[a-zA-Z0-9-]+)*$
    ...    example=dc01,mail
    ...    default=""
    
     
     # Smart Auto-discovery logic
     IF    "${AUTO_DISCOVER_DNS_RESOURCES}" == "true"
         Log    Smart autodiscovery enabled. Analyzing actual Azure DNS configuration...
         RW.Core.Add Pre To Report    === Smart Azure DNS Autodiscovery ===
         RW.Core.Add Pre To Report    Analyzing actual Azure DNS infrastructure configuration...
         
         ${discovery_result}=    RW.CLI.Run Cli
         ...    cmd=cd ${CURDIR} && AZURE_RESOURCE_SUBSCRIPTION_ID="${AZURE_RESOURCE_SUBSCRIPTION_ID}" RESOURCE_GROUPS="${RESOURCE_GROUPS}" bash azure_dns_smart_discovery.sh
         ...    timeout_seconds=300
         
         RW.Core.Add Pre To Report    Smart autodiscovery output: ${discovery_result.stdout}
         
         # Parse discovery results
         ${discovery_exists}=    Run Keyword And Return Status    File Should Exist    ${CURDIR}/azure_dns_discovery.json
         IF    ${discovery_exists}
             ${auto_resource_groups_result}=    RW.CLI.Run Cli
             ...    cmd=cat ${CURDIR}/azure_dns_discovery.json | jq -r '.discovery.resource_groups | join(",") // ""'
             ...    timeout_seconds=30
             
             ${auto_resource_groups}=    Strip String    ${auto_resource_groups_result.stdout}
             
             ${auto_test_fqdns_result}=    RW.CLI.Run Cli
             ...    cmd=cat ${CURDIR}/azure_dns_discovery.json | jq -r '.discovery.suggested_test_fqdns | join(",") // ""'
             ...    timeout_seconds=30
             
             ${auto_test_fqdns}=    Strip String    ${auto_test_fqdns_result.stdout}
             
             ${auto_forward_zones_result}=    RW.CLI.Run Cli
             ...    cmd=cat ${CURDIR}/azure_dns_discovery.json | jq -r '.discovery.forward_lookup_zones | join(",") // ""'
             ...    timeout_seconds=30
             
             ${auto_forward_zones}=    Strip String    ${auto_forward_zones_result.stdout}
             
             ${auto_public_domains_result}=    RW.CLI.Run Cli
             ...    cmd=cat ${CURDIR}/azure_dns_discovery.json | jq -r '.discovery.public_dns_zones | join(",") // ""'
             ...    timeout_seconds=30
             
             ${auto_public_domains}=    Strip String    ${auto_public_domains_result.stdout}
             
             ${auto_express_route_result}=    RW.CLI.Run Cli
             ...    cmd=cat ${CURDIR}/azure_dns_discovery.json | jq -r '.discovery.express_route_zones | join(",") // ""'
             ...    timeout_seconds=30
             
             ${auto_express_route}=    Strip String    ${auto_express_route_result.stdout}
             
             ${auto_dns_resolvers_result}=    RW.CLI.Run Cli
             ...    cmd=cat ${CURDIR}/azure_dns_discovery.json | jq -r '.discovery.dns_resolvers | join(",") // ""'
             ...    timeout_seconds=30
             
             ${auto_dns_resolvers}=    Strip String    ${auto_dns_resolvers_result.stdout}
             
             # Use autodiscovered values if manual config is empty
             ${RESOURCE_GROUPS}=    Set Variable If    '${RESOURCE_GROUPS}' == ''    ${auto_resource_groups}    ${RESOURCE_GROUPS}
             ${TEST_FQDNS}=    Set Variable If    '${TEST_FQDNS}' == ''    ${auto_test_fqdns}    ${TEST_FQDNS}
             ${FORWARD_LOOKUP_ZONES}=    Set Variable If    '${FORWARD_LOOKUP_ZONES}' == ''    ${auto_forward_zones}    ${FORWARD_LOOKUP_ZONES}
             ${PUBLIC_DOMAINS}=    Set Variable If    '${PUBLIC_DOMAINS}' == ''    ${auto_public_domains}    ${PUBLIC_DOMAINS}
             ${EXPRESS_ROUTE_DNS_ZONES}=    Set Variable If    '${EXPRESS_ROUTE_DNS_ZONES}' == ''    ${auto_express_route}    ${EXPRESS_ROUTE_DNS_ZONES}
             ${DNS_RESOLVERS}=    Set Variable If    '${DNS_RESOLVERS}' == ''    ${auto_dns_resolvers}    ${DNS_RESOLVERS}
             
             RW.Core.Add Pre To Report    === Smart Autodiscovery Results ===
             RW.Core.Add Pre To Report    Resource Groups: ${RESOURCE_GROUPS}
             RW.Core.Add Pre To Report    Test FQDNs: ${TEST_FQDNS}
             RW.Core.Add Pre To Report    Forward Lookup Zones: ${FORWARD_LOOKUP_ZONES}
             RW.Core.Add Pre To Report    Public Domains: ${PUBLIC_DOMAINS}
             RW.Core.Add Pre To Report    Express Route Zones: ${EXPRESS_ROUTE_DNS_ZONES}
             RW.Core.Add Pre To Report    DNS Resolvers (Azure-specific): ${DNS_RESOLVERS}
             
             Log    Smart autodiscovery completed successfully. Using discovered Azure DNS infrastructure.
         ELSE
             Log    Smart autodiscovery failed. Using manual configuration.
             RW.Core.Add Issue
             ...    severity=4
             ...    expected=Smart autodiscovery should analyze Azure DNS configuration
             ...    actual=Smart autodiscovery failed - using manual configuration
             ...    title=Smart Autodiscovery Failed
             ...    reproduce_hint=Check Azure CLI authentication and permissions: az account show
             ...    details=Smart autodiscovery was enabled but failed to analyze Azure DNS infrastructure. Falling back to manual configuration.
             ...    next_steps=1. Run 'az login' to authenticate\n2. Verify permissions with 'az network private-dns zone list'\n3. Set AUTO_DISCOVER_DNS_RESOURCES=false to use manual configuration only
         END
     END
     
     # Create consolidated FQDN list for comprehensive testing
    ${all_fqdns_list}=    Create List
    IF    '${TEST_FQDNS}' != ''
        @{init_test_fqdns}=    Split String    ${TEST_FQDNS}    ,
        FOR    ${fqdn}    IN    @{init_test_fqdns}
            ${fqdn}=    Strip String    ${fqdn}
            Continue For Loop If    '${fqdn}' == ''
            Append To List    ${all_fqdns_list}    ${fqdn}
        END
    END
    IF    '${FORWARD_LOOKUP_ZONES}' != ''
        @{forward_zones}=    Split String    ${FORWARD_LOOKUP_ZONES}    ,
        FOR    ${zone}    IN    @{forward_zones}
            ${zone}=    Strip String    ${zone}
            Continue For Loop If    '${zone}' == ''
            Append To List    ${all_fqdns_list}    ${zone}
        END
    END
     IF    '${PUBLIC_DOMAINS}' != '' and '${PUBLIC_DOMAINS}' != '""'
         @{public_domains_init}=    Split String    ${PUBLIC_DOMAINS}    ,
         FOR    ${domain}    IN    @{public_domains_init}
             ${domain}=    Strip String    ${domain}
             Continue For Loop If    '${domain}' == ''
             Append To List    ${all_fqdns_list}    ${domain}
         END
     END
    
    ${ALL_TEST_FQDNS}=    Evaluate    ','.join($all_fqdns_list)
    
    # Validate configuration
    ${total_fqdns}=    Get Length    ${all_fqdns_list}
    IF    ${total_fqdns} == 0
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=At least one FQDN should be configured for testing
        ...    actual=No FQDNs found in TEST_FQDNS, FORWARD_LOOKUP_ZONES, or PUBLIC_DOMAINS
        ...    title=No DNS Targets Configured
        ...    reproduce_hint=Configure at least one of: TEST_FQDNS, FORWARD_LOOKUP_ZONES, or PUBLIC_DOMAINS
        ...    details=Configuration validation failed: No domains specified for DNS testing
        ...    next_steps=1. Set TEST_FQDNS with your important domains\n2. Or set FORWARD_LOOKUP_ZONES for on-premises domains\n3. Or set PUBLIC_DOMAINS for public website monitoring
    END
    
     # Set all suite variables
     Set Suite Variable    ${azure_credentials}
     Set Suite Variable    ${AUTO_DISCOVER_DNS_RESOURCES}
     Set Suite Variable    ${AZURE_RESOURCE_SUBSCRIPTION_ID}
     Set Suite Variable    ${RESOURCE_GROUPS}
     Set Suite Variable    ${TEST_FQDNS}
     Set Suite Variable    ${FORWARD_LOOKUP_ZONES}
     Set Suite Variable    ${DNS_RESOLVERS}
     Set Suite Variable    ${PUBLIC_DOMAINS}
     Set Suite Variable    ${EXPRESS_ROUTE_DNS_ZONES}
     Set Suite Variable    ${FORWARD_ZONE_TEST_SUBDOMAINS}
     Set Suite Variable    ${ALL_TEST_FQDNS}
