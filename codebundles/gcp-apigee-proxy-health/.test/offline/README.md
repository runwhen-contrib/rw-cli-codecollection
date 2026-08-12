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
| `healthy` | everything nominal | every check reports **zero** issues (known-negative) |
| `broken` | eight distinct known faults | every check reports **its specific** issue (known-positive) |
| `nocreds` | no access token at all | discovery reports the auth failure |
| `apierror` | valid token, `APIGEE_ORG` set, every call HTTP 403 | discovery and all three analytics tasks report the API failure |
| `absent-empty` | 200, no org for this project | failure to determine: issue raised, `status: failed` |
| `absent-apidisabled` | 403 saying the Apigee API was never enabled | failure to determine: issue raised, `status: failed` |
| `permdenied` | 403 plain PERMISSION_DENIED, no org supplied | failure to determine: issue raised, `status: failed` |
| `decoyorg` | several orgs visible, none for this project | no org adopted, issue raised |
| `multiorg` | four orgs visible, the right one **third**, the rest serving the broken dataset | exactly the project's org is selected |
| `orgprefix` | healthy fixtures, org named `organizations/<org>` | resolves to the same org, zero issues |
| `teardown-*` | shared org clean / with a leftover / unqueryable | teardown exits 0, 1, 1 |
| `bootstrap` | fixture provisioning with a broken/absent tool | exits non-zero, never prints a "Deployed" line |
| `emptyorg` | org reachable, zero proxies | `status: ok`, zero issues, report says "nothing to judge" |
| `undeployedonly` | proxies exist, deployed nowhere | both proxies flagged as undeployed |

A final **static** section reads the shipped generation rule, templates and
`runbook.robot` directly: the tier drives the bash scripts and never runs the
indexer or `robot`, so the org gate, `qualifiers: ["resource"]`, the jinja org
chain, the auth gate and the org-anchored task titles are checked by reading the
files. Comments are stripped before matching — the generation rule's own
commentary names its resource type and both qualifier forms, so matching the
whole file passed even with the gate reverted.

The known-positive half is the half that matters. A check with no
known-positive assertion is untested no matter how often it has run clean.

`nocreds` and `apierror` exist because the first two cannot catch the worst
failure: a bundle that cannot run at all. Every check correctly writes an empty
result and exits 0 in that state, so every per-check assertion passes and the
run reads as a healthy org. There is no SLI to carry that distinction, so the
signal has to be an issue — which is why those scenarios assert on
`apigee_discovery_issues.json` rather than on the checks.

`apierror` was added after a live run found what `nocreds` could not reach.
`nocreds` exercises the empty-token guard; but when `APIGEE_ORG` is supplied,
org resolution is skipped entirely, so nothing guards a 403 except checking the
HTTP status of each response. `jq '.deployments // []'` turns
`{"error":{"code":403}}` into `[]`, and every check then reads "nothing found"
as "nothing wrong". Identical reality, opposite verdicts, decided only by
whether the org name happened to be configured.

`absent-*`, `permdenied` and `decoyorg` are four different routes to one verdict:
an org that cannot be named means this run is blind, and blind is a failure.

That used to be three verdicts. Under the old rule, which matched every indexed
project, a successful list with no org — or a 403 saying the API was never
enabled — was read as "this project simply has no Apigee" and raised nothing.
The rule now gates on `gcp_apigee_organizations`, so an SLX exists only where an
organization was indexed: if the run then cannot see one, something is wrong with
the run, not with the premise. Gating on the org **deleted** the case rather than
handling it, and these four scenarios assert that each route still ends
somewhere loud.

What has not changed is the part that always mattered: `decoyorg` proves another
tenant's org is never adopted, and `multiorg` proves the right one still is. The
two are a pair — `decoyorg` alone only shows the run breaks when nothing matches,
not that it picks correctly when something does. `multiorg` places the project's
org **third** of four and serves the *broken* dataset from every other org, so
positional selection yields a clean-looking run carrying another estate's
findings rather than an obviously broken one.

**Do not assert on a field with `//`.** `jq -r '.status // "absent"'` falls
through on `false` as well as null, so an assertion written that way can pass
under the exact mutation it exists to catch. The harness uses
`if has("status") then (.status | tostring) else "absent" end`.

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

`mock/curl` shadows `curl` on `PATH` and serves fixtures from each scenario's
`routes` file:

```
<path-pattern><TAB><file-or-@literal>[<TAB><http-status>]
```

Patterns are paths **relative to the API base** (`…/v1`), first match wins,
status defaults to 200. If a pattern contains `?`, the part after it is
glob-matched against the query string; otherwise the query is ignored. An
unrouted URL returns Google's 404 body **and** is recorded in `unrouted.log`,
so a check calling an endpoint the API does not define is caught rather than
degrading to a clean "no findings" result.

Three ways this mock deliberately refuses to be kinder than the real API — each
added because a bug slipped past the earlier, friendlier version:

- **Matching is per path segment.** `*` never crosses a `/`, and a pattern only
  matches a path with the same number of segments. A shell `case` glob let `*`
  swallow slashes, so `/organizations/*/deployments` cheerfully served
  `/organizations/organizations/my-org/deployments` — a malformed URL the real
  API 404s — and the `orgprefix` mutation passed when it should have failed.
- **HTTP status is modelled**, and `-w` is honoured for `%{http_code}`. The code
  decides whether a response is usable from its status; a mock that always
  implied success let the 403-scores-healthy bug pass.
- **`-f` and `-o` behave like curl's.** With `-f`, an HTTP error suppresses the
  body and exits 22. Without that, `curl -fsS … | jq` on a 403 returned an error
  body with exit 0, and the teardown verification reported "nothing left over"
  for an org it could not query at all.

The harness self-tests its own routing before running any scenario. A
mis-routed fixture makes every downstream assertion vacuous — the checks see an
empty document, report nothing, and a known-negative-only suite reads that as
healthy.

## Proving the suite can fail

A suite only ever observed passing has demonstrated nothing. Every bug this tier
was built to catch has been reintroduced into a scratch copy and the suite
re-run; each turned it red, at the expected assertions.

Behavioural bugs, from the original build-out:

| Reintroduced bug | Assertions that went red |
|---|---|
| Deployment `state` read from the `deployments` *list* endpoint | `[healthy] deployment state clean` |
| "Deployed" gated on `state == "READY"` | `[healthy] no failed/undeployed proxies` + 5 more |
| Issues accumulated inside a `while read` pipeline subshell | `[broken] ...flags orders-api not on latest` (+ count) |
| `/environments` response indexed with a string key | all 9 analytics assertions |
| Metric read as a raw `.values[0]` | all 9 analytics assertions |
| Discovery swallowing the auth failure | 19 assertions across every scenario |
| `apigee_curl` no longer recording HTTP status | 5 `apierror` assertions |
| Fixture provisioning swallowing a `zip` failure | `[bootstrap] broken/absent zip` |
| The bootstrap tool precheck removed | `[bootstrap] broken/absent jq` |

Org anchoring, added when the rule moved from `project` to
`gcp_apigee_organizations`. Each mutation is applied to a fresh copy of the
bundle, so there is no restore step to get wrong, and the runner aborts if an
edit changed nothing — a regex that silently fails to match otherwise reads as
"not detected" when it really means "not tested".

| Mutation | Assertions that went red |
|---|---|
| Gate reverted to bare `project` | `[rule] gates on gcp_apigee_organizations`, `...no longer on bare project` |
| Gate moved to `gcp_apigee_api_proxies` | `[rule] ...nor per-proxy` |
| `qualifiers: ["project"]` | `[rule] anchored on the organization`, `...not flattened back` |
| Boolean mode dropped from the org chain | both `org fallback is in boolean mode` + both render `blank override falls through` |
| Reaching through `match_resource.resource.name` | both `materialised before use`, `never reaches through` + both render `no indexed payload degrades` |
| Final `default('', true)` removed | both render `placeholder never leaks into a config value` |
| SLX alias back to the project | `[slx] alias names the org` + render `alias names the org` |
| `scope` tag back to `Project` | `[slx] scope tag is the organization` + 2 more |
| `APIGEE_ORG` back to an inline `custom.apigee_org` | `[taskset] APIGEE_ORG is the resolved org` + render `taskset: indexed org wins` |
| Task titles back to `${GCP_PROJECT_ID}` | `[static] every task name names the org` + 1 more |
| Suite gated on the activation returncode | `[auth] activation is tolerant`, `...does not gate on the activation returncode` |
| Token-probe `IF` deleted (probe kept) | `[auth] the token probe is what gates the suite` |
| Discovery failure downgraded to `Log` | `[runbook] discovery failure fails the suite` |
| Missing-topology guard removed from a check | `[runbook] every check errors on a missing topology` |
| Org selected positionally instead of by `projectId` | all 3 `[multiorg]` assertions (10 red in total) |
| "No org" read as not-applicable again | `[decoyorg]` + `[absent-empty]` assertions |
| One issue title rescoped to the project | `[broken] every title carries the SLX scope` |
| `Fail` moved above the discovery issue loop | `[runbook] discovery's own issues are raised before the suite fails` |
| Discovery unpinned back to `runwhen-local:latest` | all 3 `[taskfile]` assertions |
| `activate-gcloud.sh` stops failing without a token | `[activate] no credentials at all is a hard failure` |
| Its `gcp.json.secret` branch removed | `[activate] a gcp.json.secret beside the script is accepted` |

The behavioural bugs above are reintroduced by appending an overriding function
definition to the end of `apigee_common.sh` — the last definition wins, so no
regex surgery is needed. (A first attempt used `perl -0pi` regexes; one silently
did not match and the green result read as "not covered" when it was really
"not tested".)

## Why docker off Linux

The check scripts target the runner image's Linux/GNU userland: GNU `date -d`
(BSD `date` has no `-d`) and bash 4+ associative arrays (macOS ships bash 3.2).
Running the tier natively on macOS would exercise a lookalike, not the thing
that ships.
