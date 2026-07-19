---
name: openrouter-spend-health
kind: skill-template
description: Monitors OpenRouter API spending by checking account balance, aggregating spend from generation logs, breaking down costs by model, comparing against budget thresholds, forecasting future spend, and detecting anomalous spending patterns. Use when tracking LLM API costs, checking credit balance, or investigating unexpected spend on OpenRouter.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [OpenRouter]
resource_types: [api_credit]
access: read-only
---

# OpenRouter Spend Health and Forecasting

## Summary

Monitors OpenRouter API spending by checking account balance, aggregating spend from generation logs, breaking down costs by model, comparing against budget thresholds, forecasting future spend from historical burn rate, and detecting anomalous spending patterns. Designed for teams using OpenRouter as their LLM API gateway who need visibility into API credit consumption and cost trends.

## Tools

### Check OpenRouter Account Balance for Account `${OPENROUTER_API_KEY_LABEL}`

Queries the OpenRouter /api/v1/auth/key endpoint for remaining credits. Raises an issue if balance is below the configured minimum threshold or if the API key is invalid or expired.

- **Robot task name**: <code>Check OpenRouter Account Balance for Account `${OPENROUTER_API_KEY_LABEL}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-openrouter-balance.sh`
- **Tags**: `access:read-only`, `data:config`
- **Reads**: `OPENROUTER_API_KEY_LABEL`, `OPENROUTER_MIN_BALANCE_USD`
- **Writes**: `balance_issues.json`
- **Issues raised**: Low balance (severity 3), invalid/expired API key (severity 4), API unreachable (severity 4)

### Review OpenRouter Spend History for Account `${OPENROUTER_API_KEY_LABEL}`

Fetches recent generation logs from /api/v1/logs, aggregates spend by day for the lookback window, and flags gaps in logging data.

- **Robot task name**: <code>Review OpenRouter Spend History for Account `${OPENROUTER_API_KEY_LABEL}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `review-openrouter-spend-history.sh`
- **Tags**: `access:read-only`, `data:logs`
- **Reads**: `OPENROUTER_API_KEY_LABEL`, `OPENROUTER_LOOKBACK_DAYS`
- **Writes**: `spend_history_issues.json`
- **Issues raised**: No logs found (severity 2), missing data gaps (severity 2), API fetch failure (severity 3)

### Analyze OpenRouter Spend by Model for Account `${OPENROUTER_API_KEY_LABEL}`

Breaks down spend per model from the logs endpoint. Identifies the top-N most expensive models and flags any model whose share exceeds a configured concentration threshold.

- **Robot task name**: <code>Analyze OpenRouter Spend by Model for Account `${OPENROUTER_API_KEY_LABEL}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `analyze-openrouter-spend-by-model.sh`
- **Tags**: `access:read-only`, `data:metrics`
- **Reads**: `OPENROUTER_API_KEY_LABEL`, `OPENROUTER_LOOKBACK_DAYS`, `OPENROUTER_SPEND_CONCENTRATION_THRESHOLD`
- **Writes**: `model_spend_issues.json`
- **Issues raised**: Model concentration risk (severity 3), API fetch failure (severity 3)

### Check OpenRouter Budget Status for Account `${OPENROUTER_API_KEY_LABEL}`

Compares total cumulative spend against a configured budget threshold. Raises an issue if spend exceeds the budget or is projected to exceed it before the next reset period.

- **Robot task name**: <code>Check OpenRouter Budget Status for Account `${OPENROUTER_API_KEY_LABEL}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-openrouter-budget.sh`
- **Tags**: `access:read-only`, `data:config`
- **Reads**: `OPENROUTER_API_KEY_LABEL`, `OPENROUTER_BUDGET_USD`
- **Writes**: `budget_issues.json`
- **Issues raised**: Budget exceeded (severity 4), budget depletion risk (severity 3), API unreachable (severity 4)

### Forecast OpenRouter Spend Trend for Account `${OPENROUTER_API_KEY_LABEL}`

Computes average daily burn rate from the last N days of spend history, projects spend for the next period, and flags if projected spend would exceed the configured budget.

- **Robot task name**: <code>Forecast OpenRouter Spend Trend for Account `${OPENROUTER_API_KEY_LABEL}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `forecast-openrouter-spend.sh`
- **Tags**: `access:read-only`, `data:metrics`
- **Reads**: `OPENROUTER_API_KEY_LABEL`, `OPENROUTER_LOOKBACK_DAYS`, `OPENROUTER_BUDGET_USD`, `OPENROUTER_BALANCE_ALERT_WINDOW_DAYS`
- **Writes**: `forecast_issues.json`
- **Issues raised**: Projected monthly budget overrun (severity 3), balance depletion imminent (severity 4), API fetch failure (severity 3)

### Detect OpenRouter Spend Anomalies for Account `${OPENROUTER_API_KEY_LABEL}`

Analyzes daily spend totals for statistical outliers using a z-score method. Flags days where spend deviates from the baseline by more than the configured threshold.

- **Robot task name**: <code>Detect OpenRouter Spend Anomalies for Account `${OPENROUTER_API_KEY_LABEL}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `detect-openrouter-spend-anomalies.sh`
- **Tags**: `access:read-only`, `data:metrics`
- **Reads**: `OPENROUTER_API_KEY_LABEL`, `OPENROUTER_LOOKBACK_DAYS`, `OPENROUTER_ANOMALY_STDDEV_THRESHOLD`
- **Writes**: `anomaly_issues.json`
- **Issues raised**: Spend spike (severity 3), spend acceleration (severity 3), API fetch failure (severity 3)

## Monitor

Measures OpenRouter API spend health by scoring API reachability, balance sufficiency, budget adherence, anomaly absence, and model concentration risk. Produces a value between 0 (completely failing) and 1 (fully passing).

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of sub-checks below
- **Recommended interval**: `300s`

### Sub-checks

#### Score API Reachability for `${OPENROUTER_API_KEY_LABEL}`

Binary 1 if the OpenRouter /api/v1/auth/key endpoint returns a valid response within timeout.

- **Robot task name**: <code>Score API Reachability for `${OPENROUTER_API_KEY_LABEL}`</code>
- **Sub-metric name**: `api_reachable`
- **Tags**: `access:read-only`, `data:metrics`
- **Pass condition**: HTTP 200 from `/api/v1/auth/key`

#### Score Balance Sufficiency for `${OPENROUTER_API_KEY_LABEL}`

Binary 1 if remaining account balance is above the minimum threshold.

- **Robot task name**: <code>Score Balance Sufficiency for `${OPENROUTER_API_KEY_LABEL}`</code>
- **Sub-metric name**: `balance_sufficient`
- **Tags**: `access:read-only`, `data:config`
- **Reads**: `OPENROUTER_MIN_BALANCE_USD`
- **Pass condition**: `credits >= OPENROUTER_MIN_BALANCE_USD`

#### Score Budget Adherence for `${OPENROUTER_API_KEY_LABEL}`

Binary 1 if budget is disabled (0) or cumulative spend is under the configured budget.

- **Robot task name**: <code>Score Budget Adherence for `${OPENROUTER_API_KEY_LABEL}`</code>
- **Sub-metric name**: `budget_adherent`
- **Tags**: `access:read-only`, `data:config`
- **Reads**: `OPENROUTER_BUDGET_USD`
- **Pass condition**: `budget == 0 OR usage <= budget`

#### Score Anomaly Status for `${OPENROUTER_API_KEY_LABEL}`

Binary 1 if no spend anomalies (spikes or acceleration) are detected in the lookback window.

- **Robot task name**: <code>Score Anomaly Status for `${OPENROUTER_API_KEY_LABEL}`</code>
- **Sub-metric name**: `no_anomalies`
- **Underlying script**: `detect-openrouter-spend-anomalies.sh`
- **Tags**: `access:read-only`, `data:metrics`
- **Reads**: `OPENROUTER_LOOKBACK_DAYS`, `OPENROUTER_ANOMALY_STDDEV_THRESHOLD`
- **Pass condition**: zero anomaly issues detected

#### Score Model Concentration for `${OPENROUTER_API_KEY_LABEL}`

Binary 1 if no single model exceeds the configured concentration threshold.

- **Robot task name**: <code>Score Model Concentration for `${OPENROUTER_API_KEY_LABEL}`</code>
- **Sub-metric name**: `model_concentration_ok`
- **Underlying script**: `analyze-openrouter-spend-by-model.sh`
- **Tags**: `access:read-only`, `data:metrics`
- **Reads**: `OPENROUTER_LOOKBACK_DAYS`, `OPENROUTER_SPEND_CONCENTRATION_THRESHOLD`
- **Pass condition**: zero concentration issues detected

#### Generate OpenRouter Spend Health Score for `${OPENROUTER_API_KEY_LABEL}`

Averages sub-scores (API reachable, balance sufficient, budget adherent, no anomalies, model concentration ok) into the final 0-1 metric for alerting.

- **Robot task name**: <code>Generate OpenRouter Spend Health Score for `${OPENROUTER_API_KEY_LABEL}`</code>
- **Sub-metric name**: *(aggregate — no sub_name)*
- **Tags**: `access:read-only`, `data:metrics`
- **Pass condition**: `(api_reachable + balance_sufficient + budget_adherent + no_anomalies + model_concentration_ok) / 5`

## Inputs

| Variable | Type | Default | Description |
|---|---|---|---|
| `OPENROUTER_API_KEY_LABEL` | string | `openrouter-account` | Human-readable label for the OpenRouter API key (e.g. account name or email). |
| `OPENROUTER_LOOKBACK_DAYS` | string | `7` | Number of days of historical spend to analyze. |
| `OPENROUTER_BUDGET_USD` | string | `0` | Total budget threshold in USD for the current period. Set to 0 to disable budget checks. |
| `OPENROUTER_MIN_BALANCE_USD` | string | `10` | Minimum remaining balance threshold in USD. |
| `OPENROUTER_SPEND_CONCENTRATION_THRESHOLD` | string | `50` | Maximum percentage of total spend allowed per model before flagging a concentration risk. |
| `OPENROUTER_BALANCE_ALERT_WINDOW_DAYS` | string | `7` | Days to project forward for balance depletion alerts. |
| `OPENROUTER_ANOMALY_STDDEV_THRESHOLD` | string | `2` | Number of standard deviations for anomaly detection threshold. |

## Secrets

| Secret | Type | Description |
|---|---|---|
| `openrouter_api_key` | string | OpenRouter API key for authentication. Bearer token sent in Authorization header. |

## Outputs

### JSON Artifacts (runbook)

- `balance_issues.json` — Issues from account balance check
- `spend_history_issues.json` — Issues from spend history review
- `model_spend_issues.json` — Issues from model spend concentration analysis
- `budget_issues.json` — Issues from budget status check
- `forecast_issues.json` — Issues from spend forecasting
- `anomaly_issues.json` — Issues from anomaly detection

### Monitor Metrics (sli)

- `api_reachable` — 0 or 1: API endpoint reachable
- `balance_sufficient` — 0 or 1: balance above minimum threshold
- `budget_adherent` — 0 or 1: spend within budget
- `no_anomalies` — 0 or 1: no spend anomalies detected
- `model_concentration_ok` — 0 or 1: no model exceeds concentration threshold
- *(aggregate)* — 0.0–1.0: arithmetic mean of all sub-checks

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path, e.g.
`/home/runwhen/collection/codebundles/openrouter-spend-health/runbook.robot`.

Tools and monitors are selected by the platform from the SLX `pathToRobot`
reference — not by invoking `ro` or bare `robot` locally.

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` for authoring and
manual test runs. It is **not** the enterprise runtime.

```bash
cd codebundles/openrouter-spend-health
export OPENROUTER_API_KEY=sk-or-...
ro runbook.robot
```

### Standalone scripts (no Robot)

```bash
export OPENROUTER_API_KEY=sk-or-...
export OPENROUTER_LOOKBACK_DAYS=7
export OPENROUTER_BUDGET_USD=100
export OPENROUTER_MIN_BALANCE_USD=10

./check-openrouter-balance.sh
./review-openrouter-spend-history.sh
./analyze-openrouter-spend-by-model.sh
./check-openrouter-budget.sh
./forecast-openrouter-spend.sh
./detect-openrouter-spend-anomalies.sh
```

## Source files

| Script | Purpose |
|---|---|
| `runbook.robot` | Robot Framework runbook with 6 spend health investigation tasks |
| `sli.robot` | Robot Framework SLI with 5 sub-checks plus aggregate health score |
| `check-openrouter-balance.sh` | Queries `/api/v1/auth/key` for remaining credits and API key validity |
| `review-openrouter-spend-history.sh` | Fetches and aggregates generation logs by day, flags data gaps |
| `analyze-openrouter-spend-by-model.sh` | Breaks down spend per model, flags concentration risk |
| `check-openrouter-budget.sh` | Compares lifetime spend against configured budget threshold |
| `forecast-openrouter-spend.sh` | Computes burn rate, projects future spend, flags depletion risk |
| `detect-openrouter-spend-anomalies.sh` | Z-score based anomaly detection for daily spend spikes and acceleration |