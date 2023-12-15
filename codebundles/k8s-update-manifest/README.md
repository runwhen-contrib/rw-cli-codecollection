# Kubernetes Manifest Update
Provides various tasks for updating kubernetes manifest in Git to suggest changes via version control and GitOps.

# TaskSet
- `REPO_URI`: The Git URL where the source code resides.
- `REPO_AUTH_TOKEN`: An oauth2 token used to authenticate with the infrastructure repo.
- `WORKLOAD_NAME`: The name of the workload, used for search quality.
- `REPO_MANIFEST_PATH`: A path to the manifest file.
- `INCREASE_AMOUNT`: How many replicas to increase the HPA by.
- `REPLICA_MAX`: The maximum allowed replicas for the scale amount.