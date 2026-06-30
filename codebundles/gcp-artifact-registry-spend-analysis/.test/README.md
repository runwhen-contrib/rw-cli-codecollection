# Test infrastructure

This CodeBundle analyzes BigQuery billing export data. Integration tests require an existing organization billing export table and GCP credentials with BigQuery read access.

Run static validation from this directory:

```bash
task
```

For live integration testing, configure `GCP_BILLING_EXPORT_TABLE` and `GOOGLE_APPLICATION_CREDENTIALS`, then execute individual task scripts from the bundle root.
