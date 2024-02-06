*** Settings ***
Documentation       This runbook provides a comprehensive guide to managing and troubleshooting DNS configurations for Runwhen.com.
...    It outlines steps for checking DNS configurations, testing DNS resolution using the Dig command, and analyzing network traffic with Tcpdump.
...    Additionally, it includes procedures for conducting DNS health checks and interpreting DNS logs for potential errors.
...    This runbook is essential for maintaining optimal DNS performance and resolving any related issues promptly.
Metadata            Author    Jonathan Funk
Metadata            Display Name    linux-dns-resolution
Metadata            Supports    `Linux`, `DNS Issue`, `Runwhen.com`, `DNS Settings`, `Developer Report`, `Incident Investigation`, `Issue Resolution`, 

Library             BuiltIn
Library             RW.Core
Library             RW.platform
Library             OperatingSystem
Library             String
Library             Process

Suite Setup         Suite Initialization

*** Tasks ***
Test DNS Resolution using Dig Command
    [Documentation]   This script is used to test DNS resolution for a specified domain using a specified DNS server. It uses the 'dig' command to perform the DNS lookup and then checks if the resolution was successful. If successful, it extracts the A record from the 'dig' command output and checks if the A record was found. The script outputs the status of the DNS resolution and the A record (if found).
    [Tags]  DNS resolution    Bash scripting    dig command    A record    DNS server    Domain name    Error handling    Shell script    Linux    Network troubleshooting    Server administration    Domain troubleshooting    IP address resolution    Google DNS    Automation    Scripting    Networking    
    ${process}=    Run Process    ${CURDIR}/test_dns_resolution_dig_command.sh    env=${env}
    RW.Core.Add Pre To Report    ${process.stdout}

Interpret DNS Logs for Errors
    [Documentation]   This bash script checks a system log file for DNS-related errors. It first verifies the existence of the log file, then searches for lines containing both "named" and "error" (case-insensitive), outputting any matches to a temporary file. The script then checks if this file is empty or not, printing its contents if it contains any lines, and finally removes the temporary file.
    [Tags]  bash script    log file    error checking    DNS errors    syslog    grep    conditional statements    file existence check    script cleanup    output redirection    text search    Linux    system administration    troubleshooting    automation    
    ${process}=    Run Process    ${CURDIR}/interpret_dns_logs_for_errors.sh    env=${env}
    RW.Core.Add Pre To Report    ${process.stdout}

Perform DNS Health Checks
    [Documentation]   This script performs a series of DNS health checks for a specified domain on a specified DNS server. It checks for various DNS record types, DNSSEC, DNS response time, and reverse DNS. The script requires the 'dig' command to be installed on the system. It outputs the results of each check, providing useful information for diagnosing DNS issues.
    [Tags]  DNS Health Check    Bash Script    DNS Records    DNSSEC    DNS Response Time    Reverse DNS    dig command    dnsutils package    Shell Scripting    Network Administration    Server Monitoring    System Administration    
    ${process}=    Run Process    ${CURDIR}/dns_health_check.sh    env=${env}
    RW.Core.Add Pre To Report    ${process.stdout}

Analyze Network Traffic with Tcpdump
    [Documentation]   This script captures and analyzes DNS traffic on a specified network interface using tcpdump. It checks for the presence of tcpdump, captures a specified number of packets on the DNS port, and then analyzes the output to count the number of DNS queries and responses. It also checks for any DNS errors in the captured traffic. The script then cleans up by removing the output file.
    [Tags]  Network Monitoring    TCPDump    DNS Traffic    Bash Scripting    Packet Capture    Error Detection    System Administration    Linux    Network Troubleshooting    Server Maintenance    DNS Queries    DNS Responses    DNS Errors    Automated Analysis    Output Analysis    Command Line Tools    Network Analysis    Data Capture    Network Security    Network Administration    
    ${process}=    Run Process    ${CURDIR}/analyze_network_traffic_tcpdump.sh    env=${env}
    RW.Core.Add Pre To Report    ${process.stdout}

Check DNS Configuration for Runwhen.com
    [Documentation]   This script is designed to perform a comprehensive check on the DNS configuration for a specified domain, in this case "runwhen.com". It checks various DNS records including A, AAAA, CNAME, MX, NS, PTR, SOA, SRV, TXT, and DNSSEC. The script also checks the connectivity to the DNS server by pinging it and verifies if the domain is resolvable. Lastly, it performs a trace route to check the overall DNS health.
    [Tags]  DNS Check    Bash Script    Domain Verification    A Record    AAAA Record    CNAME Record    MX Record    NS Record    PTR Record    SOA Record    SRV Record    TXT Record    DNSSEC    DNS Server Connectivity    Domain Resolvability    DNS Health    Network Administration    System Administration    Troubleshooting    DNS Configuration    
    ${process}=    Run Process    ${CURDIR}/check_dns_config_runwhen_com.sh    env=${env}
    RW.Core.Add Pre To Report    ${process.stdout}


*** Keywords ***
Suite Initialization

    ${DOMAIN_NAME}=    RW.Core.Import User Variable    DOMAIN_NAME
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*

    ${DNS_SERVER}=    RW.Core.Import User Variable    DNS_SERVER
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*

    ${LOG_FILE}=    RW.Core.Import User Variable    LOG_FILE
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*

    ${ERROR_KEYWORD}=    RW.Core.Import User Variable    ERROR_KEYWORD
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*

    ${DNS_KEYWORD}=    RW.Core.Import User Variable    DNS_KEYWORD
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*

    ${DOMAIN_TO_CHECK}=    RW.Core.Import User Variable    DOMAIN_TO_CHECK
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*

    ${DNS_RECORD_TYPES}=    RW.Core.Import User Variable    DNS_RECORD_TYPES
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*

    ${IP_ADDRESS}=    RW.Core.Import User Variable    IP_ADDRESS
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*

    ${TCPDUMP_PATH}=    RW.Core.Import User Variable    TCPDUMP_PATH
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*

    ${OUTPUT_FILE}=    RW.Core.Import User Variable    OUTPUT_FILE
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*

    ${INTERFACE}=    RW.Core.Import User Variable    INTERFACE
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*

    ${PORT}=    RW.Core.Import User Variable    PORT
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*

    ${PACKET_COUNT}=    RW.Core.Import User Variable    PACKET_COUNT
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*

    ${DOMAIN}=    RW.Core.Import User Variable    DOMAIN
    ...    type=string
    ...    description=Runbook input.
    ...    pattern=\w*

    Set Suite Variable    ${DOMAIN_NAME}    ${DOMAIN_NAME}
    Set Suite Variable    ${DNS_SERVER}    ${DNS_SERVER}
    Set Suite Variable    ${LOG_FILE}    ${LOG_FILE}
    Set Suite Variable    ${ERROR_KEYWORD}    ${ERROR_KEYWORD}
    Set Suite Variable    ${DNS_KEYWORD}    ${DNS_KEYWORD}
    Set Suite Variable    ${DOMAIN_TO_CHECK}    ${DOMAIN_TO_CHECK}
    Set Suite Variable    ${DNS_RECORD_TYPES}    ${DNS_RECORD_TYPES}
    Set Suite Variable    ${IP_ADDRESS}    ${IP_ADDRESS}
    Set Suite Variable    ${TCPDUMP_PATH}    ${TCPDUMP_PATH}
    Set Suite Variable    ${OUTPUT_FILE}    ${OUTPUT_FILE}
    Set Suite Variable    ${INTERFACE}    ${INTERFACE}
    Set Suite Variable    ${PORT}    ${PORT}
    Set Suite Variable    ${PACKET_COUNT}    ${PACKET_COUNT}
    Set Suite Variable    ${DOMAIN}    ${DOMAIN}

    Set Suite Variable
    ...    &{env}
    ...    DOMAIN_NAME=${DOMAIN_NAME}
    ...    DNS_SERVER=${DNS_SERVER}
    ...    LOG_FILE=${LOG_FILE}
    ...    ERROR_KEYWORD=${ERROR_KEYWORD}
    ...    DNS_KEYWORD=${DNS_KEYWORD}
    ...    DOMAIN_TO_CHECK=${DOMAIN_TO_CHECK}
    ...    DNS_RECORD_TYPES=${DNS_RECORD_TYPES}
    ...    IP_ADDRESS=${IP_ADDRESS}
    ...    TCPDUMP_PATH=${TCPDUMP_PATH}
    ...    OUTPUT_FILE=${OUTPUT_FILE}
    ...    INTERFACE=${INTERFACE}
    ...    PORT=${PORT}
    ...    PACKET_COUNT=${PACKET_COUNT}
    ...    DOMAIN=${DOMAIN}