# Testing auth0-tenant-health CodeBundle

This directory contains validation scripts for the `auth0-tenant-health`
CodeBundle.

## What is tested

The `validate-all-tests.sh` script performs **static, network-free** validation:

- Required files exist (`runbook.robot`, `sli.robot`, `README.md`, generation
  rules, templates, bash scripts).
- Bash scripts are present, executable, and pass `bash -n` syntax checks.
- `runbook.robot` includes the required `RW.Core`/`RW.CLI` imports,
  `Documentation`, and `Force Tags`.

## Running the tests

```bash
cd .test
task validate-all-tests
```

or directly:

```bash
cd .test
./validate-all-tests.sh
```

## Live integration testing

Full integration against a real Auth0 tenant requires live Management API
credentials. To run the scripts manually against a tenant:

```bash
export AUTH0_TENANT="mytenant"
export AUTH0_MGMT_CREDENTIALS='{"client_id":"...","client_secret":"..."}'
# or AUTH0_MGMT_CREDENTIALS="<raw MAPI token>"
./tenant_availability.sh
./custom_domain_health.sh
./analyze_error_logs.sh
./login_failure_analysis.sh
./rate_limit_health.sh
./log_stream_health.sh
```

The machine-to-machine client used for credentials must be granted
`read:logs`, `read:custom_domains`, `read:log_streams`, and
`read:tenant_settings` scopes. The tenant must have the Management API
enabled.