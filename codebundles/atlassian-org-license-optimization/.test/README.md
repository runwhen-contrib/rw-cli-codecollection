# Test Infrastructure

This bundle uses mock JSON fixtures instead of live Atlassian API calls for CI-friendly validation.

## Scenarios

| Scenario | Description | Expected issues |
|----------|-------------|-----------------|
| `no_reclamation_candidates` | All billable users active; no stale invites | 0 |
| `inactive_jira_users` | 5+ inactive Jira billable users | ≥1 |
| `overlap_and_invites` | Product overlap + 8 stale pending invites | ≥2 |

## Run Tests

```bash
cd .test
task
```

Or run individual scripts:

```bash
./validate-bundle-structure.sh
./validate-all-tests.sh
```

## Terraform

Live Atlassian organizations cannot be provisioned via Terraform. Mock fixtures in `fixtures/` provide deterministic test data aligned with the design spec scenarios.
