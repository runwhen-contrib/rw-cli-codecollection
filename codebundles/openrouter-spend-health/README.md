# OpenRouter Spend Health and Forecasting

This CodeBundle monitors OpenRouter API spending by checking account balance, aggregating spend from generation logs, breaking down costs by model, comparing against budget thresholds, forecasting future spend from historical burn rate, and detecting anomalous spending patterns.

## Overview

- **Check Account Balance**: Queries `/api/v1/key` for current key metadata and remaining limit (`limit_remaining`), and uses management endpoints (`/api/v1/keys`, `/api/v1/workspaces`, `/api/v1/credits`) when available.
- **Review Spend History**: Fetches `/api/v1/activity` per day (up to 30 days) and aggregates spend by day, flagging gaps in activity data.
- **Analyze Spend by Model**: Breaks down spend per model from `/api/v1/activity` and flags concentration risk when a single model exceeds the configured threshold.
- **Check Budget Status**: Compares current-period spend against a configured budget and raises issues when exceeded.
- **Forecast Spend Trend**: Computes average daily burn rate from activity data and projects future spend, flagging budget overrun risks.
- **Detect Spend Anomalies**: Analyzes daily spend for statistical outliers using z-score and acceleration detection.

## Configuration

### Required Variables

- `OPENROUTER_API_KEY_LABEL`: Human-readable label for the OpenRouter API key (e.g. account name or email).

### Optional Variables

- `OPENROUTER_LOOKBACK_DAYS`: Number of days of historical spend to analyze (default: `7`).
- `OPENROUTER_BUDGET_USD`: Total budget threshold in USD for the current period. Set to `0` to disable budget checks (default: `0`).
- `OPENROUTER_MIN_BALANCE_USD`: Minimum remaining balance threshold in USD (default: `10`).
- `OPENROUTER_SPEND_CONCENTRATION_THRESHOLD`: Maximum percentage of total spend allowed per model before flagging concentration risk (default: `50`).
- `OPENROUTER_BALANCE_ALERT_WINDOW_DAYS`: Days to project forward for balance depletion alerts (default: `7`).
- `OPENROUTER_ANOMALY_STDDEV_THRESHOLD`: Number of standard deviations for anomaly detection (default: `2`).

### Secrets

- `openrouter_api_key`: OpenRouter API key for authentication. A plain text API key string sent as a Bearer token in the Authorization header.

## Tasks Overview

### Check OpenRouter Account Balance
Queries `/api/v1/key` for current key metadata. For management keys, also checks `/api/v1/keys`, `/api/v1/workspaces`, and `/api/v1/credits`. Raises a severity 3 issue if remaining limit is below threshold, or severity 4 if authentication fails.

### Review OpenRouter Spend History
Fetches activity rows from `/api/v1/activity` by day (management key required), aggregates spend by day, and flags missing days. Raises severity 2 if no data is found and severity 3 on API/access failures.

### Analyze OpenRouter Spend by Model
Breaks down spend per model from `/api/v1/activity`. Flags a severity 3 issue if any single model exceeds the configured concentration threshold.

### Check OpenRouter Budget Status
Compares current-period usage (`usage_monthly` when available) against the configured budget. Raises severity 3-4 issues if the budget is exceeded or depletion risk is detected.

### Forecast OpenRouter Spend Trend
Computes average daily burn rate and projects spend forward from activity data. Raises severity 3-4 issues if projected monthly spend exceeds budget or if depletion is imminent.

### Detect OpenRouter Spend Anomalies
Analyzes daily spend from activity data using z-score statistics. Flags severity 3 issues for spend spikes (single-day outliers) and spend acceleration (sustained burn rate increases).