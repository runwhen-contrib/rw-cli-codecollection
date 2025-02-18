*** Settings ***
Documentation       Operational tasks for an Azure App Services, such as restarting, scaling or re-deploying.
Metadata            Author    stewartshea
Metadata            Display Name    Azure App Service Operations
Metadata            Supports        Azure    AppService    Ops

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Restart App Service `${APP_SERVICE_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Restarts the Azure App Service and verifies success.
    [Tags]
    ...    azure
    ...    appservice
    ...    restart
    ...    access:read-write
    ${restart_service}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_restart.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ----------\nRestart output:\n${restart_service.stdout}

    IF  'ERROR' in $restart_service.stdout
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Azure App Service `${APP_SERVICE_NAME}` should restart successfully
        ...    actual=Restart encountered issues
        ...    title=Restart failed for App Service `${APP_SERVICE_NAME}`
        ...    reproduce_hint=Check logs from the restart command
        ...    details=${restart_service.stderr}
        ...    next_steps=Inspect Azure Portal or CLI logs for possible deployment or config issues.
    END


Swap Deployment Slots for App Service `${APP_SERVICE_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Calls the script that checks plan tier, lists slots, auto-determines source/target if only one non-prod slot
    [Tags]
    ...    azure
    ...    appservice
    ...    slot
    ...    swap
    ...    deployment
    ...    access:read-write

    ${slot_swap}=  RW.CLI.Run Bash File
    ...  bash_file=appservice_slot_swap.sh
    ...  env=${env}
    ...  timeout_seconds=180
    RW.Core.Add Pre To Report    ----------\nSlot Swap Script Output:\n${slot_swap.stdout}

    IF  'ERROR' in $slot_swap.stdout
        RW.Core.Add Issue
        ...  severity=3
        ...  expected=Slot swap for App Service should succeed
        ...  actual=Slot swap encountered issues
        ...  title=Slot swap failed
        ...  reproduce_hint=Check script logs
        ...  details=${slot_swap.stderr}
        ...  next_steps=Check Azure Portal, logs, or plan SKU
    END


Scale Up App Service `${APP_SERVICE_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Scales up the App Service to the next plan from current SKU
    [Tags]    
    ...    azure    
    ...    appservice    
    ...    scaleup
    ...    access:read-write

    ${scaleup}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_plan_scaleup.sh
    ...    env=${env}  
    ...    include_in_history=true
    ...    timeout_seconds=300
    RW.Core.Add Pre To Report    ----------\nScale-Up Script Output:\n${scaleup.stdout}

    IF  'ERROR' in $scaleup.stdout
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Azure App Service `${APP_SERVICE_NAME}` scales up successfully
        ...    actual=Scale-up encountered issues
        ...    title=Scale up failed for App Service `${APP_SERVICE_NAME}`
        ...    reproduce_hint=Check scale_up_appservice.sh logs
        ...    details=${scaleup.stderr}
        ...    next_steps=Review plan or SKU details, check resource group quotas, or contact Azure admin.
    END


Scale Down App Service `${APP_SERVICE_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]  Decreases SKU based on a predefined map (e.g. S2->S1, S1->B3, etc.)
    [Tags]  
    ...  azure  
    ...  appservice  
    ...  scaledown
    ...  access:read-write
    ${scaledown}=  RW.CLI.Run Bash File
    ...    bash_file=appservice_plan_scaledown.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=true
    RW.Core.Add Pre To Report  ----------\nScale-Down Script Output:\n${scaledown.stdout}

    IF  'ERROR' in $scaledown.stdout
        RW.Core.Add Issue
        ...  severity=3
        ...  expected=Azure App Service `${APP_SERVICE_NAME}` scales down successfully
        ...  actual=Scale-down encountered issues
        ...  title=Scale down failed for App Service `${APP_SERVICE_NAME}`
        ...  reproduce_hint=Check scale_down_appservice.sh logs
        ...  details=${scaledown.stderr}
        ...  next_steps=Review plan or SKU details, check resource group quotas, or contact Azure admin.
    END
Scale Out Instances for App Service `${APP_SERVICE_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}` by `${SCALE_OUT_FACTOR}`x
    [Documentation]    Multiplies current worker count by SCALE_OUT_FACTOR
    [Tags]    
    ...    azure    
    ...    appservice    
    ...    scaleout
    ...    access:read-write
    ${scale_out}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_scale_out.sh
    ...    env=${env}
    ...    timeout_seconds=300
    ...    include_in_history=true
    RW.Core.Add Pre To Report    ----------\nScale-Out Factor Script Output:\n${scale_out.stdout}

    IF  'ERROR' in $scale_out.stdout
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Azure App Service scaled out successfully
        ...    actual=Scale-out encountered issues
        ...    title=Scale out failed
        ...    reproduce_hint=Check scale_out_factor_appservice.sh logs
        ...    details=${scale_out.stderr}
        ...    next_steps=Check resource limits or plan constraints
    END



Scale In Instances for App Service `${APP_SERVICE_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}` to `1\/${SCALE_IN_FACTOR}`
    [Documentation]    Decreases the number of instances within the current App Service Plan
    [Tags]
    ...    azure
    ...    appservice
    ...    scalein
    ...    access:read-write
    ${scale_in}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_scale_in.sh
    ...    env=${env}
    ...    timeout_seconds=180
    RW.Core.Add Pre To Report    ----------\nScale-In Script Output:\n${scale_in.stdout}

    IF  'ERROR' in $scale_in.stdout
        
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Azure App Service scales in successfully
        ...    actual=Scale-in encountered issues
        ...    title=Scale in failed
        ...    reproduce_hint=Check scale_in_factor_unified.sh logs
        ...    details=${scale_in.stdout}
    END

Redeploy App Service `${APP_SERVICE_NAME}` from Latest Source in Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Forces a re-deployment of the Azure App Service from the configured code or container source.
    [Tags]
    ...    azure
    ...    appservice
    ...    redeploy
    ...    force
    ...    access:read-write
    ${redeploy}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_redeploy.sh
    ...    env=${env}
    ...    timeout_seconds=300
    RW.Core.Add Pre To Report    ----------\nRedeploy Output:\n${redeploy.stdout}

    IF  'ERROR' in $redeploy.stdout
        RW.Core.Add Issue
        ...  severity=3
        ...  expected=Redeployment successful
        ...  actual=Errors in redeploy output
        ...  title=Redeploy failed
        ...  details=${redeploy.stdout}
        ...  next_steps=Review the logs or the portal
    END


*** Keywords ***
Suite Initialization
    ${AZ_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZ_RESOURCE_GROUP
    ...    type=string
    ...    description=The resource group to perform actions against.
    ...    pattern=\w*
    ${APP_SERVICE_NAME}=    RW.Core.Import User Variable    APP_SERVICE_NAME
    ...    type=string
    ...    description=The Azure AppService to triage.
    ...    pattern=\w*
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    ${TIME_PERIOD_MINUTES}=    RW.Core.Import User Variable    TIME_PERIOD_MINUTES
    ...    type=string
    ...    description=The time period, in minutes, to look back for activites/events. 
    ...    pattern=\w*
    ...    default=10
    ${SCALE_OUT_FACTOR}=    RW.Core.Import User Variable    SCALE_OUT_FACTOR
    ...    type=string
    ...    description=The factor by which to increase the amount of instances within the given App Service Plan.
    ...    pattern=\w*
    ...    default=2
    ${SCALE_IN_FACTOR}=     RW.Core.Import User Variable    SCALE_IN_FACTOR
    ...    type=string
    ...    description=The factor by which to decrease the amount of instances within the given App Service Plan.
    ...    pattern=\w*
    ...    default=2
    ${SOURCE_SLOT}=     RW.Core.Import User Variable    SOURCE_SLOT
    ...    type=string
    ...    description=The source slot for deployment promotion.
    ...    pattern=\w*
    ...    example=staging
    ...    default=""
    ${TARGET_SLOT}=     RW.Core.Import User Variable    TARGET_SLOT
    ...    type=string
    ...    description=The target slot for deployment promotion.
    ...    pattern=\w*
    ...    default=""
    ...    example=production

    # Populate env dictionary for uniform usage in tasks, matching your existing pattern
    Set Suite Variable
    ...    ${env}
    ...    {"AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}","APP_SERVICE_NAME":"${APP_SERVICE_NAME}", "SCALE_IN_FACTOR":"${SCALE_IN_FACTOR}"}
