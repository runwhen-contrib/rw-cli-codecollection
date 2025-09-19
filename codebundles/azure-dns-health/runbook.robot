*** Settings ***
Documentation       This taskset performs comprehensive DNS health monitoring and validation tasks for Azure environments.
...                 Includes private/public DNS zone checks, cross-VNet resolution validation, broken record detection,
...                 HA database checks, external resolution validation, forward lookup zones, and Express Route latency monitoring.
...                 Supports multiple FQDNs, multiple zones, and both Azure-specific and generic DNS monitoring scenarios.

Metadata            Author    runwhen-contrib
Metadata            Display Name    Azure DNS Health & Monitoring (Multi-Zone)
Metadata            Supports    Azure    DNS    Private DNS    Public DNS    Forward Zones    VNet    Express Route

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
    [Tags]    azure    dns    private-dns    zone-records
    
    # Process multiple resource groups if specified
    @{resource_groups}=    Split String    ${RESOURCE_GROUPS}    ,
    
    FOR    ${rg}    IN    @{resource_groups}
        ${rg}=    Strip String    ${rg}
        Continue For Loop If    '${rg}' == ''
        
        ${zone_check_cmd}=    Set Variable    az network private-dns zone list --resource-group "${rg}" --output json | jq -r '.[] | "Zone: " + .name + " Records: " + (.numberOfRecordSets | tostring) + " RG: ${rg}"'
        
        ${rsp}=    RW.CLI.Run Cli
        ...    cmd=${zone_check_cmd}
        ...    timeout_seconds=300
        
        RW.Core.Add Pre To Report    Private DNS Zone Records Check - Resource Group: ${rg}
        RW.Core.Add Pre To Report    Command: ${zone_check_cmd}
        RW.Core.Add Pre To Report    Output: ${rsp.stdout}
        
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
    RW.Core.Add Pre To Report    Commands Used: ${history}

Check Public DNS Zone Records
    [Documentation]    Verifies record counts and integrity for public DNS zones in the specified resource group(s)
    [Tags]    azure    dns    public-dns    zone-records
    
    # Process multiple resource groups if specified
    @{resource_groups}=    Split String    ${RESOURCE_GROUPS}    ,
    
    FOR    ${rg}    IN    @{resource_groups}
        ${rg}=    Strip String    ${rg}
        Continue For Loop If    '${rg}' == ''
        
        ${zone_check_cmd}=    Set Variable    az network dns zone list --resource-group "${rg}" --output json | jq -r '.[] | "Zone: " + .name + " Records: " + (.numberOfRecordSets | tostring) + " RG: ${rg}"'
        
        ${rsp}=    RW.CLI.Run Cli
        ...    cmd=${zone_check_cmd}
        ...    timeout_seconds=300
        
        RW.Core.Add Pre To Report    Public DNS Zone Records Check - Resource Group: ${rg}
        RW.Core.Add Pre To Report    Command: ${zone_check_cmd}
        RW.Core.Add Pre To Report    Output: ${rsp.stdout}
        
        # Check for zones with minimal records (less than expected minimum)
        ${minimal_records_pattern}=    Set Variable    Records: [0-2]\\b
        ${minimal_zones}=    Get Regexp Matches    ${rsp.stdout}    ${minimal_records_pattern}
        ${minimal_count}=    Get Length    ${minimal_zones}
        IF    ${minimal_count} > 0
            RW.Core.Add Issue
            ...    severity=1
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

Validate DNS Resolution Across VNets
    [Documentation]    Tests DNS resolution from each linked infrastructure VNet to confirm records resolve correctly for multiple FQDNs
    [Tags]    azure    dns    vnet    resolution
    
    # Process multiple resource groups for VNet discovery
    @{resource_groups}=    Split String    ${RESOURCE_GROUPS}    ,
    @{test_fqdns}=    Split String    ${TEST_FQDNS}    ,
    
    FOR    ${rg}    IN    @{resource_groups}
        ${rg}=    Strip String    ${rg}
        Continue For Loop If    '${rg}' == ''
        
        # Get VNet information and test resolution
        ${vnet_list_cmd}=    Set Variable    az network vnet list --resource-group "${rg}" --output json | jq -r '.[] | .name'
        
        ${rsp}=    RW.CLI.Run Cli
        ...    cmd=${vnet_list_cmd}
        ...    timeout_seconds=300
        
        ${vnets}=    Split String    ${rsp.stdout}    \n
        
        FOR    ${vnet}    IN    @{vnets}
            ${vnet}=    Strip String    ${vnet}
            Continue For Loop If    '${vnet}' == ''
            
            # Test each FQDN from this VNet
            FOR    ${fqdn}    IN    @{test_fqdns}
                ${fqdn}=    Strip String    ${fqdn}
                Continue For Loop If    '${fqdn}' == ''
                
                # Test DNS resolution from VNet context
                ${dns_test_cmd}=    Set Variable    nslookup ${fqdn} && echo "VNet: ${vnet} FQDN: ${fqdn} - DNS Resolution: SUCCESS" || echo "VNet: ${vnet} FQDN: ${fqdn} - DNS Resolution: FAILED"
                
                ${dns_rsp}=    RW.CLI.Run Cli
                ...    cmd=${dns_test_cmd}
                ...    timeout_seconds=60
                
                RW.Core.Add Pre To Report    DNS Resolution Test - VNet: ${vnet}, FQDN: ${fqdn}
                RW.Core.Add Pre To Report    Command: ${dns_test_cmd}
                RW.Core.Add Pre To Report    Output: ${dns_rsp.stdout}
                
                ${resolution_failed}=    Run Keyword And Return Status    Should Contain    ${dns_rsp.stdout}    FAILED
                IF    ${resolution_failed}
                    RW.Core.Add Issue
                    ...    severity=2
                    ...    expected=DNS resolution should work from all VNets for all FQDNs
                    ...    actual=DNS resolution failed from VNet ${vnet} for FQDN ${fqdn}
                    ...    title=DNS Resolution Failure in VNet ${vnet} for ${fqdn}
                    ...    reproduce_hint=Test DNS resolution from VNet ${vnet} for FQDN ${fqdn}
                    ...    details=VNet: ${vnet}\nFQDN: ${fqdn}\nResource Group: ${rg}\nResult: ${dns_rsp.stdout}
                    ...    next_steps=1. Check VNet DNS configuration in ${rg}\n2. Verify private DNS zone links for ${fqdn}\n3. Test connectivity between VNet and DNS resolvers\n4. Check DNS forwarder configuration
                END
            END
        END
    END
    
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Detect Broken Record Resolution
    [Documentation]    Implements repeated pull/flush/pull DNS checks for multiple FQDNs to detect failures before TTL expiry
    [Tags]    azure    dns    resolution    consistency
    
    # Test all configured FQDNs with cache flush
    @{all_fqdns}=    Split String    ${ALL_TEST_FQDNS}    ,
    
    FOR    ${fqdn}    IN    @{all_fqdns}
        ${fqdn}=    Strip String    ${fqdn}
        Continue For Loop If    '${fqdn}' == ''
        
        ${dns_test}=    Set Variable    for i in {1..3}; do echo "=== Test $i for ${fqdn} ==="; nslookup ${fqdn}; sleep 2; sudo systemctl flush-dns 2>/dev/null || echo "DNS flush attempted"; sleep 1; done
        
        ${rsp}=    RW.CLI.Run Cli
        ...    cmd=${dns_test}
        ...    timeout_seconds=120
        
        RW.Core.Add Pre To Report    DNS Resolution Consistency Test
        RW.Core.Add Pre To Report    FQDN: ${fqdn}
        RW.Core.Add Pre To Report    Output: ${rsp.stdout}
        
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
    [Tags]    azure    dns    forward-lookup    conditional-forwarders
    
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
    [Tags]    azure    dns    external    public    resolvers
    
    # Test public domain resolution through multiple resolvers
    IF    '${PUBLIC_DOMAINS}' != ''
        @{public_domains}=    Split String    ${PUBLIC_DOMAINS}    ,
        
        FOR    ${domain}    IN    @{public_domains}
            ${domain}=    Strip String    ${domain}
            Continue For Loop If    '${domain}' == ''
            
            # Test with default resolver
            ${default_test}=    Set Variable    nslookup ${domain}
            ${default_rsp}=    RW.CLI.Run Cli
            ...    cmd=${default_test}
            ...    timeout_seconds=60
            
            # Test with Google DNS
            ${google_test}=    Set Variable    nslookup ${domain} 8.8.8.8
            ${google_rsp}=    RW.CLI.Run Cli
            ...    cmd=${google_test}
            ...    timeout_seconds=60
            
            # Test with Cloudflare DNS
            ${cloudflare_test}=    Set Variable    nslookup ${domain} 1.1.1.1
            ${cloudflare_rsp}=    RW.CLI.Run Cli
            ...    cmd=${cloudflare_test}
            ...    timeout_seconds=60
            
            RW.Core.Add Pre To Report    External DNS Resolution Validation - Domain: ${domain}
            RW.Core.Add Pre To Report    Default Resolver: ${default_rsp.stdout}
            RW.Core.Add Pre To Report    Google DNS (8.8.8.8): ${google_rsp.stdout}
            RW.Core.Add Pre To Report    Cloudflare DNS (1.1.1.1): ${cloudflare_rsp.stdout}
            
            # Check for resolution inconsistencies
            ${default_failed}=    Run Keyword And Return Status    Should Contain    ${default_rsp.stdout}    can't find
            ${google_failed}=    Run Keyword And Return Status    Should Contain    ${google_rsp.stdout}    can't find
            ${cloudflare_failed}=    Run Keyword And Return Status    Should Contain    ${cloudflare_rsp.stdout}    can't find
            
            ${total_failures}=    Evaluate    ${default_failed} + ${google_failed} + ${cloudflare_failed}
            
            IF    ${total_failures} > 0
                RW.Core.Add Issue
                ...    severity=2
                ...    expected=Public domain should resolve through all DNS resolvers
                ...    actual=Public domain ${domain} resolution failed through ${total_failures} resolver(s)
                ...    title=External DNS Resolution Inconsistency for ${domain}
                ...    reproduce_hint=Test DNS resolution for ${domain} through multiple resolvers
                ...    details=Domain: ${domain}\nDefault: ${default_rsp.stdout}\nGoogle: ${google_rsp.stdout}\nCloudflare: ${cloudflare_rsp.stdout}
                ...    next_steps=1. Check DNS forwarder configuration\n2. Verify upstream DNS connectivity\n3. Review firewall rules for DNS traffic\n4. Test network connectivity to external resolvers
            END
            
            # Check for complete resolution failures across all resolvers
            IF    ${total_failures} == 3
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
    [Tags]    azure    dns    express-route    latency    performance
    
    # Test DNS query latency through Express Route for multiple zones
    IF    '${EXPRESS_ROUTE_DNS_ZONES}' != ''
        @{express_route_zones}=    Split String    ${EXPRESS_ROUTE_DNS_ZONES}    ,
        
        FOR    ${zone}    IN    @{express_route_zones}
            ${zone}=    Strip String    ${zone}
            Continue For Loop If    '${zone}' == ''
            
            # Perform multiple DNS queries to measure latency
            ${latency_test}=    Set Variable    for i in {1..10}; do echo "Query $i for ${zone}:"; time nslookup test.${zone} 2>&1 | grep real; sleep 1; done
            
            ${latency_rsp}=    RW.CLI.Run Cli
            ...    cmd=${latency_test}
            ...    timeout_seconds=180
            
            RW.Core.Add Pre To Report    Express Route DNS Latency Check - Zone: ${zone}
            RW.Core.Add Pre To Report    Latency Results: ${latency_rsp.stdout}
            
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
    
    # Test for packet drops using ping to multiple DNS servers
    IF    '${DNS_SERVER_IPS}' != ''
        @{dns_servers}=    Split String    ${DNS_SERVER_IPS}    ,
        
        FOR    ${dns_server}    IN    @{dns_servers}
            ${dns_server}=    Strip String    ${dns_server}
            Continue For Loop If    '${dns_server}' == ''
            
            ${ping_test}=    Set Variable    ping -c 10 ${dns_server} | grep "packet loss"
            ${ping_rsp}=    RW.CLI.Run Cli
            ...    cmd=${ping_test}
            ...    timeout_seconds=60
            
            RW.Core.Add Pre To Report    DNS Server Connectivity Test - Server: ${dns_server}
            RW.Core.Add Pre To Report    Ping Results: ${ping_rsp.stdout}
            
            ${packet_loss}=    Run Keyword And Return Status    Should Match Regexp    ${ping_rsp.stdout}    [1-9][0-9]*% packet loss
            IF    ${packet_loss}
                RW.Core.Add Issue
                ...    severity=2
                ...    expected=No packet loss to DNS servers through Express Route
                ...    actual=Packet loss detected to DNS server ${dns_server}
                ...    title=Packet Loss to DNS Server ${dns_server} Through Express Route
                ...    reproduce_hint=Test connectivity to DNS server ${dns_server}
                ...    details=DNS Server: ${dns_server}\nPing Results: ${ping_rsp.stdout}
                ...    next_steps=1. Check Express Route health\n2. Review network path to DNS server ${dns_server}\n3. Monitor Express Route performance\n4. Check for network congestion
            END
            
            # Check for complete connectivity failures
            ${ping_failed}=    Run Keyword And Return Status    Should Contain    ${ping_rsp.stdout}    100% packet loss
            IF    ${ping_failed}
                RW.Core.Add Issue
                ...    severity=3
                ...    expected=DNS servers should be reachable through Express Route
                ...    actual=Complete connectivity failure to DNS server ${dns_server}
                ...    title=DNS Server ${dns_server} Unreachable Through Express Route
                ...    reproduce_hint=Test network connectivity to DNS server ${dns_server}
                ...    details=DNS Server: ${dns_server} is completely unreachable\nPing Results: ${ping_rsp.stdout}
                ...    next_steps=1. Check Express Route status\n2. Verify DNS server ${dns_server} is operational\n3. Review network routing\n4. Check firewall rules\n5. Validate Express Route peering
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
    
    # Import required configuration variables
    ${RESOURCE_GROUPS}=    RW.Core.Import User Variable    RESOURCE_GROUPS
    ...    type=string
    ...    description=Comma-separated list of Azure resource groups containing DNS zones and VNets
    ...    pattern=.*
    ...    example=my-plink-rg,production-rg,network-rg
    
    ${TEST_FQDNS}=    RW.Core.Import User Variable    TEST_FQDNS
    ...    type=string
    ...    description=Comma-separated list of FQDNs to test for DNS resolution across VNets
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
    
    ${PUBLIC_DOMAINS}=    RW.Core.Import User Variable    PUBLIC_DOMAINS
    ...    type=string
    ...    description=Comma-separated list of public domains for external resolution validation (optional)
    ...    pattern=.*
    ...    example=example.com,mycompany.com
    ...    default=""
    
    ${EXPRESS_ROUTE_DNS_ZONES}=    RW.Core.Import User Variable    EXPRESS_ROUTE_DNS_ZONES
    ...    type=string
    ...    description=Comma-separated list of DNS zones accessed through Express Route for latency testing (optional)
    ...    pattern=.*
    ...    example=internal.company.com,corp.company.com
    ...    default=""
    
    ${FORWARD_LOOKUP_ZONES}=    RW.Core.Import User Variable    FORWARD_LOOKUP_ZONES
    ...    type=string
    ...    description=Comma-separated list of forward lookup zones to test (optional)
    ...    pattern=.*
    ...    example=internal.company.com,corp.local
    ...    default=""
    
    ${FORWARD_ZONE_TEST_SUBDOMAINS}=    RW.Core.Import User Variable    FORWARD_ZONE_TEST_SUBDOMAINS
    ...    type=string
    ...    description=Comma-separated list of subdomains to test in forward lookup zones (optional)
    ...    pattern=.*
    ...    example=dc01,mail,web
    ...    default=""
    
    ${DNS_SERVER_IPS}=    RW.Core.Import User Variable    DNS_SERVER_IPS
    ...    type=string
    ...    description=Comma-separated list of DNS server IP addresses for connectivity testing (optional)
    ...    pattern=.*
    ...    example=10.0.0.4,10.0.1.4
    ...    default=""
    
    # Create consolidated FQDN list for comprehensive testing
    ${all_fqdns_list}=    Create List
    IF    '${TEST_FQDNS}' != ''
        @{test_fqdns}=    Split String    ${TEST_FQDNS}    ,
        FOR    ${fqdn}    IN    @{test_fqdns}
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
    IF    '${PUBLIC_ZONES}' != ''
        @{public_zones}=    Split String    ${PUBLIC_ZONES}    ,
        FOR    ${zone}    IN    @{public_zones}
            ${zone}=    Strip String    ${zone}
            Continue For Loop If    '${zone}' == ''
            Append To List    ${all_fqdns_list}    ${zone}
        END
    END
    
    ${ALL_TEST_FQDNS}=    Evaluate    ','.join($all_fqdns_list)
    
    # Set all suite variables
    Set Suite Variable    ${azure_credentials}
    Set Suite Variable    ${RESOURCE_GROUPS}
    Set Suite Variable    ${TEST_FQDNS}
    Set Suite Variable    ${FORWARD_LOOKUP_ZONES}
    Set Suite Variable    ${PUBLIC_ZONES}
    Set Suite Variable    ${DNS_RESOLVERS}
    Set Suite Variable    ${PUBLIC_DOMAINS}
    Set Suite Variable    ${EXPRESS_ROUTE_DNS_ZONES}
    Set Suite Variable    ${FORWARD_ZONE_TEST_SUBDOMAINS}
    Set Suite Variable    ${DNS_SERVER_IPS}
    Set Suite Variable    ${ALL_TEST_FQDNS}
