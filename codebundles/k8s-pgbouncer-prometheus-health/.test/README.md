# Test infrastructure

Prerequisites: Docker, a kubeconfig copied to `kubeconfig.secret` beside this Taskfile, and at least one Kubernetes `Service` whose name matches the CodeBundle generation rules (substring `pgbouncer`).

Run `task default` from this directory to generate `workspaceInfo.yaml` and execute RunWhen Local discovery against the configured branch.
