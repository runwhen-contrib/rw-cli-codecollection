# Testing — ovirt-engine-health

This bundle talks to a live oVirt engine REST API, so testing means pointing it
at a reachable engine. There is no cloud infrastructure to provision (and no
Terraform), because oVirt is self-hosted.

## What you need

A reachable oVirt engine. Any of these works:
- An existing oVirt / RHV / OLVM engine you have read access to.
- A lab/self-hosted-engine deployment.
- The upstream `ovirt-engine` appliance for a throwaway environment.

A read-only user with the auth profile is sufficient (e.g. a user in the
`@internal` profile with `UserRole` / `ReadOnlyAdmin`).

## Configure

Create a `.test/.env` file (gitignored) or export the variables:

```bash
OVIRT_ENGINE_URL=https://engine.example.com
OVIRT_USERNAME=admin@internal
OVIRT_PASSWORD=changeme
# Optional:
OVIRT_CA_CERT_FILE=/path/to/engine-ca.pem   # for TLS verification
OVIRT_STORAGE_FREE_PCT=10
OVIRT_EVENT_LOOKBACK=1h
OVIRT_SNAPSHOT_MAX_AGE=7d
MAX_PAUSED_VMS=0
OVIRT_ENGINE_NAME=lab-ovirt
```

> Fetch the engine CA with:
> `curl -sk https://engine.example.com/ovirt-engine/services/pki-resource?resource=ca-certificate&format=X509-PEM-CA -o engine-ca.pem`

## Run

```bash
task check-config     # validate required env vars
task smoke-scripts    # run the raw check scripts and print their JSON
task run-sli          # run sli.robot (pushes the composite health score)
task run-runbook      # run runbook.robot (raises issues + writes a report)
task                  # check-config + run-sli + run-runbook
task clean            # remove robot output dirs
```

`smoke-scripts` is the fastest way to confirm connectivity and that the engine's
JSON shape matches what the scripts expect, without Robot Framework.

## No engine handy? Use the mock

`mock/` contains a dependency-free mock oVirt engine so you can exercise the
full bundle flow with no real engine and no cloud cost:

```bash
task test-mock                        # start mock, run all check scripts, tear down
task test-mock MOCK_SCENARIO=healthy  # nominal data (SLI score == 1, no issues)
task mock                             # run mock in the foreground on :8080
task run-sli-mock                     # run sli.robot against the mock (needs RW libs)
```

See `mock/README.md` for details and the scenarios it ships. The mock validates
the bundle's wiring and parsing against the documented v4 API shape; it does not
replace a one-time check against a real engine.
