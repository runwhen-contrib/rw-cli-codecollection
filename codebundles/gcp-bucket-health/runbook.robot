*** Settings ***
Documentation       Inspect GCP Storage bucket usage and configuration.
Metadata            Author    stewartshea
Metadata            Display Name    GCP Storage Bucket Health
Metadata            Supports    GCP,GCS

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Fetch GCP Bucket Storage Utilization for `${PROJECT_IDS}`