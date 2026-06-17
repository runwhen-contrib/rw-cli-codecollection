# Testing mongodb-atlas-operations-health

This bundle talks to the live MongoDB Atlas Admin API. Automated tests in CI are limited to shell syntax checks so we never embed real Atlas API keys.

## Prerequisites

- MongoDB Atlas project with a Project Read Only (or higher) API key
- `ATLAS_PROJECT_ID` and credentials matching the workspace secret format documented in the bundle `README.md`

## Local validation

From `.test/`:

```bash
task validate-scripts
```

## Manual integration

Export `ATLAS_PROJECT_ID` and either `ATLAS_PUBLIC_API_KEY` / `ATLAS_PRIVATE_API_KEY` or `ATLAS_API_KEY_CREDENTIALS` JSON, then run individual scripts from the bundle root, for example:

```bash
cd ..
./check-atlas-open-alerts.sh
```

Expect `atlas_*_issues.json` files and human-readable stdout suitable for Robot `Add Pre To Report`.
