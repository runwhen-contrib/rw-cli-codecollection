# GCP Cloud Function Health
This code checks if any GCP (Google Cloud Platform) cloud functions are unhealthy, covering both gen1 and gen2 functions. It uses the gcloud command-line tool to interact with GCP APIs and retrieve the necessary information.

> Note: Only cloud functions v1 is supported at this time for automatic discovery with the RunWhen Local Discovery Process. The tasks support both generations.

## SLI
The SLI produces a binary health score: **1** only if every health dimension passes, **0** if any is degraded. Dimensions scored (each pushed as a sub-metric with its raw issue count):

- **Function state** — no functions (gen1/gen2) in a non-ACTIVE state
- **IAM configuration** — no functions granting invoker access to `allUsers`/`allAuthenticatedUsers`
- **Build health** — no failed deployments or failed Cloud Build jobs
- **Gen2 Cloud Run health** — all gen2 backing services Ready with traffic on the latest revision

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
This codebundle authenticates with a GCP service account (`gcp_credentials`, activated via `gcloud auth activate-service-account`) scoped to `${GCP_PROJECT_ID}`. All operations are read-only.

**Granular IAM permissions**

 - `cloudfunctions.functions.get` — `gcloud functions describe` (config / scaling)
 - `cloudfunctions.functions.list` — `gcloud functions list`
 - `cloudfunctions.functions.getIamPolicy` — `gcloud functions get-iam-policy` (public-invoker check)
 - `run.services.get` — `gcloud run services describe` (gen2 backing Cloud Run service)
 - `run.services.list`
 - `cloudbuild.builds.list` — `gcloud builds list` (failed-build detection)
 - `logging.logEntries.list` — `gcloud logging read` (ERROR logs)

**Suggested predefined role(s)**

 - `roles/cloudfunctions.viewer` — covers `cloudfunctions.functions.get/list/getIamPolicy`
 - `roles/run.viewer` — covers `run.services.get/list` (gen2 Cloud Run describe)
 - `roles/cloudbuild.builds.viewer` — covers `cloudbuild.builds.list`
 - `roles/logging.viewer` — covers `logging.logEntries.list`

> Requires the Cloud Functions, Cloud Run, Cloud Build, and Cloud Logging APIs enabled on the project.
