# GCP Cloud Function Health
This code checks if any GCP (Google Cloud Platform) cloud functions are unhealthy, covering both gen1 and gen2 functions. It uses the gcloud command-line tool to interact with GCP APIs and retrieve the necessary information.

> Note: Only cloud functions v1 is supported at this time for automatic discovery with the RunWhen Local Discovery Process. The tasks support both generations.

## SLI
The SLI counts the number of cloud functions (gen1 and gen2) that are not in an ACTIVE state and pushes the metric.

## TaskSet
The Taskset provides the following tasks:

- **List Unhealthy Cloud Functions in GCP Project** — functions (gen1 + gen2) whose state/status is not ACTIVE, with per-generation state message details
- **Get Error Logs for Unhealthy Cloud Functions in GCP Project** — ERROR logs from the last 14 days; gen1 logs under `resource.type=cloud_function`, gen2 under `resource.type=cloud_run_revision`
- **Fetch Cloud Function Configurations** — full config dump (runtime, memory, timeout, ingress, VPC, service account) for every function; flags functions using the default compute service account
- **Check Cloud Function IAM Policies** — flags functions granting invoker access to `allUsers` or `allAuthenticatedUsers` (publicly invocable)
- **Check Gen2 Cloud Run Service Health** — Ready conditions, revision health, and traffic routing on the Cloud Run services backing gen2 functions
- **Check for Failed Cloud Function Builds** — non-ACTIVE deployments (state messages) and failed Cloud Build jobs
- **Check Cloud Function Scaling and Timeout Configuration** — long HTTP timeouts, gen2 functions without a max instance cap

## Requirements
The following permissions are required on the GCP service account used with the gcloud utility:

 - `cloudfunctions.functions.get`
 - `cloudfunctions.functions.list`
 - `cloudfunctions.functions.getIamPolicy`
 - `run.services.get`
 - `run.services.list`
 - `cloudbuild.builds.list`
 - `logging.logEntries.list`
