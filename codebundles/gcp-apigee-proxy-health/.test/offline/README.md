# Offline assertion tier — gcp-apigee-proxy-health

Runs every check script against fixture API responses. No credentials, no cloud
access, no network — safe to gate every PR.

```bash
./run_offline_tests.sh          # native on Linux, docker elsewhere
FORCE_DOCKER=1 ./run_offline_tests.sh
```

Exits non-zero if any assertion fails. Artifacts (stdout, stderr with the `set
-x` trace, issue JSON, request logs) are preserved under `.artifacts/`.

## What it asserts

| Scenario | Fixtures | Assertion |
|---|---|---|
| `healthy` | everything nominal | every check reports **zero** issues (known-negative), SLI scores 1.00 |
| `broken` | eight distinct known faults | every check reports **its specific** issue (known-positive), SLI scores 0.00 |
| `nocreds` | no access token at all | discovery reports the auth failure; SLI aggregate **and every sub-score** are 0 |
| `apierror` | valid token, `APIGEE_ORG` set, every call HTTP 403 | discovery and all three analytics tasks report the API failure; SLI 0.00 |
| `noapigee` | API answers 200, no org linked to this project | a **severity 4** note only; SLI 1.00 |

The known-positive half is the half that matters. A check with no
known-positive assertion is untested no matter how often it has run clean.

The last three exist because the first two cannot catch the worst failure: a
bundle that cannot run at all. Every check correctly writes an empty result and
exits 0 in that state, so every script-level assertion passes — and the score
reads as perfect health. Only an assertion at the scoring layer sees it.

`apierror` was added after a live run found what `nocreds` could not reach.
`nocreds` exercises the empty-token guard; but when `APIGEE_ORG` is supplied,
org resolution is skipped entirely, so nothing guards a 403 except checking the
HTTP status of each response. `jq '.deployments // []'` turns
`{"error":{"code":403}}` into `[]`, and every check then reads "nothing found"
as "nothing wrong". Identical reality, opposite verdicts, decided only by
whether the org name happened to be configured.

`noapigee` guards the other direction. "The API failed" and "the API says there
is no Apigee here" are different facts, and collapsing them makes the bundle
both cry wolf and miss outages: every non-Apigee project in a workspace would
sit at 0.0 forever, while a genuinely broken Apigee scored 1.0. Distinguishing
them is only possible because `apigee_curl` records HTTP status.

**Severity is load-bearing.** Only severity 1–3 gates the SLI; severity 4 is
housekeeping. Filing the "no Apigee org here" note at severity 3 would restore
the permanent false alarm, so the tier asserts its severity explicitly rather
than just its presence.

Ground truth built into `fixtures/broken`:

| Fault | Fixture | Check that must catch it |
|---|---|---|
| Deployment in `ERROR` state with non-empty `errors[]` | `status_error_payments.json` | `check_deployment_state.sh` |
| `orders-api` on rev 2 in prod, latest is 3 | `deployments.json` + `apis.json` | `check_revision_drift.sh` |
| `orders-api` runs different revisions per env | `deployments.json` | `check_revision_drift.sh` |
| `payments-api` rev 5 failed to deploy | `status_error_payments.json` | `check_failed_deployments.sh` |
| `legacy-api` deployed nowhere | `apis.json` + `deployments.json` | `check_failed_deployments.sh` |
| `payments-api` has 25 revisions (threshold 20) | `apis.json` | `check_revision_accumulation.sh` |
| Long-running operation `done` with `error` | `operations.json` | `check_failed_operations.sh` |
| policy_error 5%, target_error 7.75%, 401 10%, 429 10%, p95 9000 ms | `stats_*_prod.json` | `analyze_error_split.sh`, `analyze_http_error_rates.sh`, `analyze_latency_split.sh` |

## Fixture provenance

Shapes are derived from the Apigee Management API **discovery document**, not
from what these scripts expect:

```bash
curl -sf "https://apigee.googleapis.com/\$discovery/rest?version=v1"
```

Fixtures here were derived from revision `20260626`. A fixture written from the
implementation encodes the implementation's assumptions and therefore passes
while it is wrong. **If a fixture is ever edited to make a failing test pass,
assume the bug is reproducing itself and re-derive from the discovery
document.**

### Traps the fixtures deliberately reproduce

The real API is unkind in these specific ways, so the fixtures are too. A stub
kinder than reality lets the bug pass offline and fail in production.

1. **`Deployment.state` and `Deployment.errors[]` are absent from the org-wide
   list.** The discovery doc marks both *"displayed only when viewing deployment
   status"*, and `organizations.deployments.list` has no parameter to request
   it. `deployments.json` therefore omits them; `status_error_payments.json`
   carries them at
   `organizations/{org}/environments/{env}/apis/{api}/revisions/{rev}/deployments`,
   which is where they actually come from.

2. **`/environments` returns a bare JSON array.** It has no `list` method in
   the discovery document (only `POST /environments` and
   `GET /environments/{env}` exist); it is an Edge-compatibility path returning
   `["prod","test"]` rather than an object. Anything doing `.environments // []`
   on that response gets a jq error, not a list — and a jq error inside
   `for x in $(...)` silently yields an empty loop.

   `/apis/{api}/revisions` has no `list` method either, and is not used:
   revisions come from `apis.list?includeRevisions=true`, which is documented
   and returns every proxy's `revision[]` and `latestRevisionId` in one call.

3. **`Metric.values` come in two shapes.** The discovery doc documents both —
   `["39.0"]` *and* `[{"value":"39.0","timestamp":…}]` — with the object form
   appearing when `timeUnit` is requested. The `healthy` fixtures use the bare
   form and the `broken` fixtures use the object form, so the parsing helper is
   asserted against both rather than whichever one the code happens to expect.

4. **`DimensionMetric.name` is comma-joined and marked deprecated** in favour of
   `individualNames`. Fixtures carry both so either parsing strategy can be
   asserted against.

5. **`OperationMetadata` has no `createTime`.** Its fields are
   `targetResourceName`, `state`, `warnings`, `operationType`, `progress`.
   `operations.json` carries no timestamp anywhere, because the real response
   does not either — so any lookback window computed from one is inert.

## Mock transport

`mock/curl` shadows `curl` on `PATH` and serves fixtures by URL glob from each
scenario's `routes` file:

```
<url-glob><TAB><file-or-@literal>[<TAB><http-status>]
```

first match wins, `?` escaped as `[?]`, status defaults to 200. An unrouted URL
returns Google's standard 404 body **and** is recorded in `unrouted.log`, so a
check calling an endpoint the API does not define is caught rather than
silently degrading to a clean "no findings" result.

The mock models **HTTP status, not just the body**, and honours `-w` for the
`%{http_code}` placeholder. This matters: the code decides whether a response
is usable from its status, so a mock that always implied success would let a
403-scores-healthy bug pass the offline tier — which is exactly what happened
before `apierror` existed.

The harness self-tests its own routing before running any scenario. A
mis-routed fixture makes every downstream assertion vacuous — the checks see an
empty document, report nothing, and a known-negative-only suite reads that as
healthy.

## Proving the suite can fail

A suite only ever observed passing has demonstrated nothing. Each of the six
bugs this tier was built to catch was reintroduced into a scratch copy and the
suite re-run; all six turned it red, at the expected assertions:

| Reintroduced bug | Assertions that went red |
|---|---|
| Deployment `state` read from the `deployments` *list* endpoint | `[healthy] deployment state clean`, `[healthy] SLI score` |
| "Deployed" gated on `state == "READY"` | `[healthy] no failed/undeployed proxies` + 5 more |
| Issues accumulated inside a `while read` pipeline subshell | `[broken] ...flags orders-api not on latest` (+ count) |
| `/environments` response indexed with a string key | all 9 analytics assertions |
| Metric read as a raw `.values[0]` | all 9 analytics assertions |
| SLI treating a missing discovery result as clean | all 3 `nocreds` assertions |

Reintroduce a bug by appending an overriding function definition to the end of
`apigee_common.sh` in a scratch copy — the last definition wins, so no regex
surgery is needed and the mutation cannot silently fail to apply. (A first
attempt at this used `perl -0pi` regexes; one silently did not match and the
green result read as "not covered" when it was really "not tested".)

## Why docker off Linux

The check scripts target the runner image's Linux/GNU userland: GNU `date -d`
(BSD `date` has no `-d`) and bash 4+ associative arrays (macOS ships bash 3.2).
Running the tier natively on macOS would exercise a lookalike, not the thing
that ships.
