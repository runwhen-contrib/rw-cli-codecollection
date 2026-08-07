# GCP Apigee Security and Configuration Health - Test Infrastructure

## Overview

This test infrastructure enables the Apigee and Cloud Monitoring APIs in a
GCP project and provisions a read-only service account (`apigee.readOnlyAdmin`
+ `monitoring.viewer`) that the `gcp-apigee-security-config` CodeBundle uses to
query the Apigee Admin API and Cloud Monitoring security metrics.

## Test Scenarios

The CodeBundle's scripts hit the real Apigee Admin API as exposed by the
organization/project being tested, so the health/security conditions detected
(e.g., expiring TLS aliases, missing quotas, over-broad app scopes, low
security score, plaintext target servers) depend on the actual Apigee org:

- **healthy_security**: A properly configured org with valid certs, sensible
  quotas, least-privilege apps, high security score, TLS-enabled targets.
- **expiring_cert**: An org containing a keystore alias expiring within
  `CERT_EXPIRY_WARNING_DAYS`.
- **over_scoped_app_and_low_score**: An org with an over-scoped developer app
  and a security score below `SECURITY_SCORE_THRESHOLD`.

## Prerequisites

1. GCP project with an Apigee organization provisioned (Apigee X, hybrid, or
   classic Edge as appropriate).
2. Service account or user with permission to enable APIs and grant IAM roles.
3. `gcloud` CLI configured.

## Setup

1. Create `terraform/tf.secret` with:
   ```
   export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account-key.json"
   export TF_VAR_project_id="your-gcp-project-id"
   ```

2. Run:
   ```bash
   task build-infra
   ```

3. Export the service account key produced for the reader, then run discovery:
   ```bash
   task default
   ```
