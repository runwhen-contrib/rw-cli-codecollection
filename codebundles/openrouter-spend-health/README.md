# OpenRouter Spend Health and Forecasting

This CodeBundle monitors OpenRouter API spending by checking account balance, aggregating spend from generation logs, breaking down costs by model, comparing against budget thresholds, forecasting future spend from historical burn rate, and detecting anomalous spending patterns.

## Overview

- **Check Account Balance**: Queries the OpenRouter API for remaining credits and raises an issue if the balance is below the minimum threshold.
- **Review Spend History**: Fetches recent generation logs and aggregates spend by day, flagging gaps in logging data.
- **Analyze Spend by Model**: Breaks down spend per model and flags concentration risk when a single model exceeds the configured threshold.
- **Check Budget Status**: Compares lifetime spend against a configured budget and raises issues when exceeded.
- **Forecast Spend Trend**: Computes average daily burn rate and projects future spend, flagging budget overrun risks.
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
Queries the `/api/v1/auth/key` endpoint for remaining credits. Raises a severity 3 issue if the balance is below the configured minimum threshold, or a severity 4 issue if the API key is invalid or expired.

### Review OpenRouter Spend History
Fetches generation logs from `/api/v1/logs` with pagination, aggregates spend by day, and flags any days with missing data. Raises a severity 2 issue if no logs are found or if data gaps exist.

### Analyze OpenRouter Spend by Model
Breaks down spend per model from the logs endpoint. Flags a severity 3 issue if any single model exceeds the configured concentration threshold.

### Check OpenRouter Budget Status
Compares lifetime spend from `/api/v1/auth/key` against the configured budget. Raises severity 3-4 issues if the budget is exceeded or depletion risk is detected.

### Forecast OpenRouter Spend Trend
Computes average daily burn rate and projects spend forward. Raises severity 3-4 issues if projected monthly spend exceeds the budget or if balance depletion is imminent.

### Detect OpenRouter Spend Anomalies
Analyzes daily spend using z-score statistics. Flags severity 3 issues for spend spikes (single-day outliers) and spend acceleration (sustained burn rate increases).