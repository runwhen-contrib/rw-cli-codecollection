*** Settings ***
Documentation       This taskset performs comprehensive DNS health monitoring and validation tasks.
...                 Includes DNS zone record validation, broken DNS resolution detection,
...                 forward lookup zone testing, external resolution validation, and latency monitoring.
...                 Provides detailed issue reporting with severity levels and actionable next steps.
...                 Supports multiple FQDNs, zones, and generic DNS monitoring scenarios.

Metadata            Author    stewartshea
Metadata            Display Name    DNS Health & Monitoring
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
Check DNS Zone Records
    [Documentation]    Verifies DNS zones and their record integrity
    [Tags]    access:read-only    dns    zone-records
    
    # Check if we have any zones to test
    IF    '${DNS_ZONES}' == ''
        RW.Core.Add Pre To Report    === DNS Zone Health Check ===
        RW.Core.Add Pre To Report    No DNS zones configured for health check
        RETURN
    END
    
    @{dns_zones}=    Split String    ${DNS_ZONES}    ,
    
    FOR    ${zone}    IN    @{dns_zones}
        ${zone}=    Strip String    ${zone}
        Continue For Loop If    '${zone}' == ''
        
        RW.Core.Add Pre To Report    === DNS Zone Health Check ===
        RW.Core.Add Pre To Report    Checking zone: ${zone}
        
        # Check zone health by querying NS records
        ${ns_check}=    RW.CLI.Run Cli
        ...    cmd=dig NS ${zone} +short +timeout=10
        ...    timeout_seconds=15
        
        # Check zone health by querying SOA records
        ${soa_check}=    RW.CLI.Run Cli
        ...    cmd=dig SOA ${zone} +short +timeout=10
        ...    timeout_seconds=15
        
        RW.Core.Add Pre To Report    NS Records: ${ns_check.stdout}
        RW.Core.Add Pre To Report    SOA Record: ${soa_check.stdout}
        
        # Check for missing NS records
        ${ns_result}=    Strip String    ${ns_check.stdout}
        ${ns_empty}=    Run Keyword And Return Status    Should Be Empty    ${ns_result}
        ${ns_failed}=    Run Keyword And Return Status    Should Not Be Equal As Integers    ${ns_check.returncode}    0
        IF    ${ns_empty} or ${ns_failed}
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=DNS zone should have NS records
            ...    actual=No NS records found for zone ${zone}
            ...    title=Missing NS Records for ${zone}
            ...    reproduce_hint=Check DNS zone configuration for ${zone}
            ...    details=NS query failed for ${zone}: ${ns_check.stderr}
            ...    next_steps=1. Verify zone ${zone} exists\n2. Check DNS server configuration\n3. Verify zone delegation
        END
        
        # Check for missing SOA records
        ${soa_result}=    Strip String    ${soa_check.stdout}
        ${soa_empty}=    Run Keyword And Return Status    Should Be Empty    ${soa_result}
        ${soa_failed}=    Run Keyword And Return Status    Should Not Be Equal As Integers    ${soa_check.returncode}    0
        IF    ${soa_empty} or ${soa_failed}
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=DNS zone should have SOA record
            ...    actual=No SOA record found for zone ${zone}
            ...    title=Missing SOA Record for ${zone}
            ...    reproduce_hint=Check DNS zone configuration for ${zone}
            ...    details=SOA query failed for ${zone}: ${soa_check.stderr}
            ...    next_steps=1. Verify zone ${zone} exists\n2. Check DNS server configuration\n3. Verify zone authority
        END
    END
    
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    === Task Summary ===
    RW.Core.Add Pre To Report    DNS zone health check completed for all specified zones.
    RW.Core.Add Pre To Report    Commands Used: ${history}

Detect Broken Record Resolution
    [Documentation]    Implements repeated DNS checks for multiple FQDNs to detect resolution failures
    [Tags]    access:read-only    dns    resolution    consistency
    
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
            ...    next_steps=1. Check DNS configuration for ${fqdn}\n2. Verify DNS zone records\n3. Check DNS server health\n4. Verify TTL settings
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
    [Tags]    access:read-only    dns    forward-lookup    conditional-forwarders
    
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
    [Documentation]    Tests resolution of multiple public domains through multiple resolvers
    [Tags]    access:read-only    dns    external    public    resolvers
    
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

DNS Latency Check
    [Documentation]    Tests DNS query latency for configured zones
    [Tags]    access:read-only    dns    latency    performance
    
    # Create consolidated list of domains to test for latency
    ${all_latency_domains_list}=    Create List
    
    # Add DNS zones
    IF    '${DNS_ZONES}' != '' and '${DNS_ZONES}' != '""'
        @{dns_zones}=    Split String    ${DNS_ZONES}    ,
        FOR    ${zone}    IN    @{dns_zones}
            ${zone}=    Strip String    ${zone}
            Continue For Loop If    '${zone}' == '' or '${zone}' == '""'
            Append To List    ${all_latency_domains_list}    ${zone}
        END
    END
    
    # Add test FQDNs
    IF    '${TEST_FQDNS}' != '' and '${TEST_FQDNS}' != '""'
        @{test_fqdns}=    Split String    ${TEST_FQDNS}    ,
        FOR    ${fqdn}    IN    @{test_fqdns}
            ${fqdn}=    Strip String    ${fqdn}
            Continue For Loop If    '${fqdn}' == '' or '${fqdn}' == '""'
            Append To List    ${all_latency_domains_list}    ${fqdn}
        END
    END
    
    # Add forward lookup zones
    IF    '${FORWARD_LOOKUP_ZONES}' != '' and '${FORWARD_LOOKUP_ZONES}' != '""'
        @{forward_zones}=    Split String    ${FORWARD_LOOKUP_ZONES}    ,
        FOR    ${zone}    IN    @{forward_zones}
            ${zone}=    Strip String    ${zone}
            Continue For Loop If    '${zone}' == '' or '${zone}' == '""'
            Append To List    ${all_latency_domains_list}    ${zone}
        END
    END
    
    # Test DNS query latency for all configured domains
    ${domain_count}=    Get Length    ${all_latency_domains_list}
    IF    ${domain_count} > 0
        FOR    ${domain}    IN    @{all_latency_domains_list}
            # Perform multiple DNS queries to measure latency
            ${latency_test}=    Set Variable    for i in {1..5}; do echo "Query $i for ${domain}:"; (time nslookup ${domain} 2>&1) 2>&1 | grep -E "real|user|sys"; sleep 1; done
            
            ${latency_rsp}=    RW.CLI.Run Cli
            ...    cmd=${latency_test}
            ...    timeout_seconds=120
            
            RW.Core.Add Pre To Report    DNS Latency Check - Domain: ${domain}
            RW.Core.Add Pre To Report    Latency Results: ${latency_rsp.stdout}
            
            # Check if no timing data was captured (domain doesn't exist)
            ${no_timing_data}=    Run Keyword And Return Status    Should Be Empty    ${latency_rsp.stdout}
            IF    ${no_timing_data}
                RW.Core.Add Issue
                ...    severity=1
                ...    expected=DNS latency data should be available for domain ${domain}
                ...    actual=No latency data captured for domain ${domain} - domain may not exist
                ...    title=DNS Latency Data Unavailable for ${domain}
                ...    reproduce_hint=Test DNS resolution for ${domain} to verify domain existence
                ...    details=Domain: ${domain}\nReason: Domain may not exist or DNS resolution failed\nLatency Results: ${latency_rsp.stdout}
                ...    next_steps=1. Verify that ${domain} domain exists\n2. Check DNS configuration for ${domain}\n3. Ensure proper DNS server setup
            END
            
            # Extract latency values and check for high latency
            ${high_latency_pattern}=    Set Variable    real\\s+0m([5-9]|[1-9][0-9])\\.[0-9]+s
            ${high_latency_matches}=    Get Regexp Matches    ${latency_rsp.stdout}    ${high_latency_pattern}
            ${high_latency_count}=    Get Length    ${high_latency_matches}
            
            IF    ${high_latency_count} > 2
                RW.Core.Add Issue
                ...    severity=2
                ...    expected=DNS queries should have low latency (<5 seconds)
                ...    actual=Found ${high_latency_count} DNS queries with high latency (>5 seconds) for domain ${domain}
                ...    title=High DNS Latency for ${domain}
                ...    reproduce_hint=Test DNS query latency for domain ${domain}
                ...    details=Domain: ${domain}\nHigh latency queries: ${high_latency_count}\nResults: ${latency_rsp.stdout}
                ...    next_steps=1. Check DNS server performance\n2. Review network connectivity\n3. Monitor DNS server load\n4. Check for network congestion
            END
        END
    ELSE
        RW.Core.Add Pre To Report    DNS Latency Check - No domains configured for latency testing
    END
    
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

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
    
    
    ${FORWARD_ZONE_TEST_SUBDOMAINS}=    RW.Core.Import User Variable    FORWARD_ZONE_TEST_SUBDOMAINS
    ...    type=string
    ...    description=Specific servers to test in forward lookup zones (optional). Example: dc01,mail,web
    ...    pattern=^$|^[a-zA-Z0-9-]+(,[a-zA-Z0-9-]+)*$
    ...    example=dc01,mail
    ...    default=""
    
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
    Set Suite Variable    ${TEST_FQDNS}
    Set Suite Variable    ${FORWARD_LOOKUP_ZONES}
    Set Suite Variable    ${DNS_RESOLVERS}
    Set Suite Variable    ${PUBLIC_DOMAINS}
    Set Suite Variable    ${DNS_ZONES}
    Set Suite Variable    ${FORWARD_ZONE_TEST_SUBDOMAINS}
    Set Suite Variable    ${ALL_TEST_FQDNS}
