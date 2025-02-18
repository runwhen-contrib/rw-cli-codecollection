*** Settings ***
Documentation       Operational tasks for an Azure App Services
Metadata            Author    stewartshea
Metadata            Display Name    Azure App Service Operations
Metadata            Supports        Azure    App Service

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

    IF    $restart_service.stderr != ""
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=Azure App Service `${APP_SERVICE_NAME}` should restart successfully
        ...    actual=Restart encountered issues
        ...    title=Restart failed for App Service `${APP_SERVICE_NAME}`
        ...    reproduce_hint=Check logs from the restart command
        ...    details=${restart_service.stderr}
        ...    next_steps=Inspect Azure Portal or CLI logs for possible deployment or config issues.
    END


# Swap Deployment Slots for App Service `${APP_SERVICE_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`
#     [Documentation]    Performs a slot swap to promote or rollback code changes.
#     [Tags]
#     ...    azure
#     ...    appservice
#     ...    slot
#     ...    swap
#     ...    deployment
#     # This example assumes you have SOURCE_SLOT and TARGET_SLOT variables, or hard-code them if needed.
#     ${slot_swap}=    RW.CLI.Run Cli
#     ...    cmd=az webapp deployment slot swap --name ${APP_SERVICE_NAME} --resource-group ${AZ_RESOURCE_GROUP} --slot ${SOURCE_SLOT} --target-slot ${TARGET_SLOT}
#     ...    env=${env}
#     ...    timeout_seconds=180
#     ...    include_in_history=true
#     RW.Core.Add Pre To Report    ----------\nSlot Swap Output:\n${slot_swap.stdout}

#     IF    ${slot_swap.stderr} == ""
#         # Optionally verify deployment is healthy
#         ${verify_slot_swap}=    RW.CLI.Run Cli
#         ...    cmd=az webapp show --name ${APP_SERVICE_NAME} --resource-group ${AZ_RESOURCE_GROUP} --slot ${TARGET_SLOT}
#         ...    env=${env}
#         ...    timeout_seconds=180
#         ...    include_in_history=false
#         RW.Core.Add Pre To Report    ----------\nSlot Swap Verification:\n${verify_slot_swap.stdout}
#     ELSE
#         RW.Core.Add Issue
#         ...    severity=3
#         ...    expected=Slot swap for App Service `${APP_SERVICE_NAME}` should succeed
#         ...    actual=Slot swap encountered issues
#         ...    title=Slot swap failed for `${SOURCE_SLOT}` -> `${TARGET_SLOT}`
#         ...    reproduce_hint=Check logs from the slot swap command
#         ...    details=${slot_swap.stderr}
#         ...    next_steps=Inspect App Service logs and Azure Portal for errors or conflicts.
#     END


# Scale Up App Service `${APP_SERVICE_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`
#     [Documentation]    Scales the Azure App Service up to a higher tier or plan.
#     [Tags]
#     ...    azure
#     ...    appservice
#     ...    scaleup
#     # Example: from Basic to Standard, or Standard to Premium. Adjust the plan name as needed.
#     ${scale_up}=    RW.CLI.Run Cli
#     ...    cmd=az webapp up --name ${APP_SERVICE_NAME} --resource-group ${AZ_RESOURCE_GROUP} --plan ${NEW_APP_SERVICE_PLAN}
#     ...    env=${env}
#     ...    timeout_seconds=300
#     ...    include_in_history=true
#     RW.Core.Add Pre To Report    ----------\nScale-Up Output:\n${scale_up.stdout}

#     IF    ${scale_up.stderr} != ""
#         RW.Core.Add Issue
#         ...    severity=3
#         ...    expected=Azure App Service `${APP_SERVICE_NAME}` should scale up successfully
#         ...    actual=Scale-up encountered issues
#         ...    title=Scale up failed for App Service `${APP_SERVICE_NAME}`
#         ...    reproduce_hint=Check `az webapp up` command
#         ...    details=${scale_up.stderr}
#         ...    next_steps=Review plan or SKU details, check resource group quotas, or contact Azure admin.
#     END


# Scale Out (Increase Instances) for App Service `${APP_SERVICE_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`
#     [Documentation]    Increases the number of instances within the current App Service Plan.
#     [Tags]
#     ...    azure
#     ...    appservice
#     ...    scaleout
#     # This example sets the "–number-of-workers" argument
#     ${scale_out}=    RW.CLI.Run Cli
#     ...    cmd=az webapp scale --name ${APP_SERVICE_NAME} --resource-group ${AZ_RESOURCE_GROUP} --number-of-workers ${SCALE_OUT_WORKERS}
#     ...    env=${env}
#     ...    timeout_seconds=180
#     ...    include_in_history=true
#     RW.Core.Add Pre To Report    ----------\nScale-Out Output:\n${scale_out.stdout}

#     IF    ${scale_out.stderr} != ""
#         RW.Core.Add Issue
#         ...    severity=3
#         ...    expected=Azure App Service `${APP_SERVICE_NAME}` should scale out successfully
#         ...    actual=Scale-out encountered issues
#         ...    title=Scale out failed for App Service `${APP_SERVICE_NAME}`
#         ...    reproduce_hint=Check `az webapp scale` command
#         ...    details=${scale_out.stderr}
#         ...    next_steps=Check subscription resource limits or plan constraints.
#     END


# Scale In (Reduce Instances) for App Service `${APP_SERVICE_NAME}` in Resource Group `${AZ_RESOURCE_GROUP}`
#     [Documentation]    Decreases the number of instances within the current App Service Plan.
#     [Tags]
#     ...    azure
#     ...    appservice
#     ...    scalein
#     ${scale_in}=    RW.CLI.Run Cli
#     ...    cmd=az webapp scale --name ${APP_SERVICE_NAME} --resource-group ${AZ_RESOURCE_GROUP} --number-of-workers ${SCALE_IN_WORKERS}
#     ...    env=${env}
#     ...    timeout_seconds=180
#     ...    include_in_history=true
#     RW.Core.Add Pre To Report    ----------\nScale-In Output:\n${scale_in.stdout}

#     IF    ${scale_in.stderr} != ""
#         RW.Core.Add Issue
#         ...    severity=3
#         ...    expected=Azure App Service `${APP_SERVICE_NAME}` should scale in successfully
#         ...    actual=Scale-in encountered issues
#         ...    title=Scale in failed for App Service `${APP_SERVICE_NAME}`
#         ...    reproduce_hint=Check `az webapp scale` command
#         ...    details=${scale_in.stderr}
#         ...    next_steps=Review plan or usage, ensure the requested instance count is valid.
#     END


# Redeploy App Service `${APP_SERVICE_NAME}` from Latest Source in Resource Group `${AZ_RESOURCE_GROUP}`
#     [Documentation]    Forces a re-deployment of the Azure App Service from the configured code or container source.
#     [Tags]
#     ...    azure
#     ...    appservice
#     ...    redeploy
#     ...    force
#     ${pre_logs}=    RW.CLI.Run Bash File
#     ...    bash_file=appservice_logs.sh
#     ...    env=${env}
#     ...    timeout_seconds=180
#     ...    include_in_history=false
#     RW.Core.Add Pre To Report    ----------\nPre Redeploy Logs:\n${pre_logs.stdout}

#     ${redeploy}=    RW.CLI.Run Cli
#     ...    cmd=az webapp deployment source config-zip --resource-group ${AZ_RESOURCE_GROUP} --name ${APP_SERVICE_NAME} --src ${ZIP_PACKAGE_PATH}
#     ...    env=${env}
#     ...    timeout_seconds=300
#     ...    include_in_history=true
#     RW.Core.Add Pre To Report    ----------\nRedeploy Output:\n${redeploy.stdout}

#     IF    ${redeploy.stderr} == ""
#         ${post_logs}=    RW.CLI.Run Bash File
#         ...    bash_file=appservice_logs.sh
#         ...    env=${env}
#         ...    timeout_seconds=180
#         ...    include_in_history=false
#         RW.Core.Add Pre To Report    ----------\nPost Redeploy Logs:\n${post_logs.stdout}
#     ELSE
#         RW.Core.Add Issue
#         ...    severity=3
#         ...    expected=Azure App Service `${APP_SERVICE_NAME}` redeploys successfully
#         ...    actual=Redeploy encountered issues
#         ...    title=Redeploy failed for App Service `${APP_SERVICE_NAME}`
#         ...    reproduce_hint=Check `az webapp deployment source config-zip` logs
#         ...    details=${redeploy.stderr}
#         ...    next_steps=Examine deployment logs and local code bundle for errors.
#     END


*** Keywords ***
Suite Initialization
    # Reuse variables from your existing Azure codebundle
    ${AZ_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZ_RESOURCE_GROUP
    ${APP_SERVICE_NAME}=     RW.Core.Import User Variable    APP_SERVICE_NAME
    ${azure_credentials}=    RW.Core.Import Secret    azure_credentials
    ${TIME_PERIOD_MINUTES}=  RW.Core.Import User Variable    TIME_PERIOD_MINUTES
    ${SCALE_OUT_WORKERS}=    RW.Core.Import User Variable    SCALE_OUT_WORKERS
    ...    default=3
    ${SCALE_IN_WORKERS}=     RW.Core.Import User Variable    SCALE_IN_WORKERS
    ...    default=1
    ${NEW_APP_SERVICE_PLAN}=     RW.Core.Import User Variable    NEW_APP_SERVICE_PLAN
    ...    default=MyUpgradedPlan
    ${SOURCE_SLOT}=          RW.Core.Import User Variable    SOURCE_SLOT
    ...    default=staging
    ${TARGET_SLOT}=          RW.Core.Import User Variable    TARGET_SLOT
    ...    default=production
    ${ZIP_PACKAGE_PATH}=     RW.Core.Import User Variable    ZIP_PACKAGE_PATH
    ...    default=./appservice_package.zip

    # Populate env dictionary for uniform usage in tasks, matching your existing pattern
    Set Suite Variable
    ...    ${env}
    ...    {"AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}","APP_SERVICE_NAME":"${APP_SERVICE_NAME}"}
    # ...        "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}",
    # ...        "APP_SERVICE_NAME":"${APP_SERVICE_NAME}",
    # ...        "TIME_PERIOD_MINUTES":"${TIME_PERIOD_MINUTES}",
    # ...        "SCALE_OUT_WORKERS":"${SCALE_OUT_WORKERS}",
    # ...        "SCALE_IN_WORKERS":"${SCALE_IN_WORKERS}",
    # ...        "NEW_APP_SERVICE_PLAN":"${NEW_APP_SERVICE_PLAN}",
    # ...        "SOURCE_SLOT":"${SOURCE_SLOT}",
    # ...        "TARGET_SLOT":"${TARGET_SLOT}",
    # ...        "ZIP_PACKAGE_PATH":"${ZIP_PACKAGE_PATH}"
    # ...    }
