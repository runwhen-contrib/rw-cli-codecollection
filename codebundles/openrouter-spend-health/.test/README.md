# OpenRouter Spend Health - Test Infrastructure

This CodeBundle tests against the live OpenRouter API. No test infrastructure (Kubernetes, Terraform) is needed.

## Prerequisites

- An OpenRouter API key with access to `/api/v1/auth/key` and `/api/v1/logs` endpoints
- Environment variables set for testing

## Running Tests

```bash
task default
```

## Test Scenarios

| Scenario | Description | Expected Issues |
|---|---|---|
| healthy_account | Sufficient balance, spend within budget, no anomalies | 0 |
| low_balance | Balance below minimum threshold | 1 |
| budget_exceeded | Cumulative spend exceeds budget | 1 |
| spend_anomaly | Daily spend spike detected | 1 |
| model_concentration_risk | Single model dominates spend | 2 |