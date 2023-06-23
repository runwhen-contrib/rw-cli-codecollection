![](docs/GitHub_Banner.jpg)

# RunWhen Public Codecollection
This repository is a codecollection that is to be used within the RunWhen platform. It contains codebundles that can be used in SLIs, and TaskSets. 

Please see the **[contributing](CONTRIBUTING.md)** and **[code of conduct](CODE_OF_CONDUCT.md)** for details on adding your contributions to this project. 

Documentation for each codebundle is maintained in the README.md alongside the robot code and is published at [https://docs.runwhen.com/public/v/codebundles/](https://docs.runwhen.com/public/v/codebundles/). Please see the [readme howto](README_HOWTO.md) for details on crafting a codebundle readme that can be indexed. 
## Codebundle Index
| Name | Supported Integrations | Tasks | Documentation |
|---|---|---|---|
| [GCP Gcloud Log Inspection](https://github.com/runwhen-contrib/rw-cli-codecollection/blob/main/codebundles/gcloud-log-inspection/runbook.robot) | `GCP`, `Gcloud`, `Google Monitoring` | `Inspect GCP Logs For Common Errors` | Fetches logs from a GCP using a configurable query and raises an issue with details on the most common issues. [Docs](https://docs.runwhen.com/public/v/cli-codecollection/gcloud-log-inspection) |
| [GCP Node Prempt List](https://github.com/runwhen-contrib/rw-cli-codecollection/blob/main/codebundles/gcloud-node-preempt/sli.robot) | `GCP`, `GKE` | `Count the number of nodes in active prempt operation` | Check if any GCP nodes have an active preempt operation. [Docs](https://docs.runwhen.com/public/v/cli-codecollection/gcloud-node-preempt) |
| [GKE Kong Ingress Host Triage](https://github.com/runwhen-contrib/rw-cli-codecollection/blob/main/codebundles/curl-gmp-kong-ingress-inspection/runbook.robot) | `GCP`, `GMP`, `Ingress`, `Kong`, `Metrics` | `Check If Kong Ingress HTTP Error Rate Violates HTTP Error Threshold`, `Check If Kong Ingress HTTP Request Latency Violates Threshold`, `Check If Kong Ingress Controller Reports Upstream Errors` | Collects Kong ingress host metrics from GMP on GCP and inspects the results for ingress with a HTTP error code rate greater than zero over a configurable duration and raises issues based on the number of ingress with error codes. [Docs](https://docs.runwhen.com/public/v/cli-codecollection/curl-gmp-kong-ingress-inspection) |
| [GKE Nginx Ingress Host Triage](https://github.com/runwhen-contrib/rw-cli-codecollection/blob/main/codebundles/curl-gmp-nginx-ingress-inspection/runbook.robot) | `GCP`, `GMP`, `Ingress`, `Nginx`, `Metrics` | `Fetch Nginx Ingress Metrics From GMP And Perform Inspection On Results` | Collects Nginx ingress host controller metrics from GMP on GCP and inspects the results for ingress with a HTTP error code rate greater than zero over a configurable duration and raises issues based on the number of ingress with error codes. [Docs](https://docs.runwhen.com/public/v/cli-codecollection/curl-gmp-nginx-ingress-inspection) |
| [Kubernetes ArgoCD Application Health & Troubleshoot](https://github.com/runwhen-contrib/rw-cli-codecollection/blob/main/codebundles/k8s-argocd-application-health/runbook.robot) | `Kubernetes`, `AKS`, `EKS`, `GKE`, `OpenShift`, `ArgoCD` | `Fetch ArgoCD Application Sync Status & Health`, `Fetch ArgoCD Application Last Sync Operation Details`, `Fetch Unhealthy ArgoCD Application Resources`, `Scan For Errors in Pod Logs Related to ArgoCD Application Deployments`, `Fully Describe ArgoCD Application` | This taskset collects information and runs general troubleshooting checks against argocd application objects within a namespace. [Docs](https://docs.runwhen.com/public/v/cli-codecollection/k8s-argocd-application-health) |
| [Kubernetes Artifactory Triage](https://github.com/runwhen-contrib/rw-cli-codecollection/blob/main/codebundles/k8s-artifactory-health/runbook.robot) | `Kubernetes`, `AKS`, `EKS`, `GKE`, `OpenShift`, `Artifactory` | `Check Artifactory Liveness and Readiness Endpoints` | Performs a triage on the Open Source version of Artifactory in a Kubernetes cluster. [Docs](https://docs.runwhen.com/public/v/cli-codecollection/k8s-artifactory-health) |
| [Kubernetes CertManager Healthcheck](https://github.com/runwhen-contrib/rw-cli-codecollection/blob/main/codebundles/k8s-certmanager-healthcheck/sli.robot) | `Kubernetes`, `AKS`, `EKS`, `GKE`, `OpenShift` | `Get Health Score of CertManager Workloads` | Check the health of pods deployed by cert-manager. [Docs](https://docs.runwhen.com/public/v/cli-codecollection/k8s-certmanager-healthcheck) |
| [Kubernetes Daemonset Triage](https://github.com/runwhen-contrib/rw-cli-codecollection/blob/main/codebundles/k8s-daemonset-healthcheck/runbook.robot) | `Kubernetes`, `AKS`, `EKS`, `GKE`, `OpenShift` | `Get DaemonSet Log Details For Report`, `Get Related Daemonset Events`, `Check Daemonset Replicas` | Triages issues related to a Daemonset and its available replicas. [Docs](https://docs.runwhen.com/public/v/cli-codecollection/k8s-daemonset-healthcheck) |
| [Kubernetes Deployment Triage](https://github.com/runwhen-contrib/rw-cli-codecollection/blob/main/codebundles/k8s-deployment-healthcheck/runbook.robot) | `Kubernetes`, `AKS`, `EKS`, `GKE`, `OpenShift` | `Check Deployment Log For Issues`, `Troubleshoot Deployment Warning Events`, `Get Deployment Workload Details For Report`, `Troubleshoot Deployment Replicas`, `Check For Deployment Event Anomalies` | Triages issues related to a deployment and its replicas. [Docs](https://docs.runwhen.com/public/v/cli-codecollection/k8s-deployment-healthcheck) |
| [Kubernetes Flux Choas Testing](https://github.com/runwhen-contrib/rw-cli-codecollection/blob/main/codebundles/k8s-chaos-flux/runbook.robot) | `Kubernetes`, `AKS`, `EKS`, `GKE`, `OpenShift` | `Suspend the Flux Resource Reconciliation`, `Find Random FluxCD Workload as Chaos Target`, `Execute Chaos Command`, `Execute Additional Chaos Command`, `Resume Flux Resource Reconciliation` | This taskset is used to suspend a flux resource for the purposes of executing chaos tasks. [Docs](https://docs.runwhen.com/public/v/cli-codecollection/k8s-chaos-flux) |
| [Kubernetes FluxCD HelmRelease TaskSet](https://github.com/runwhen-contrib/rw-cli-codecollection/blob/main/codebundles/k8s-fluxcd-helm-health/runbook.robot) | `Kubernetes`, `AKS`, `EKS`, `GKE`, `OpenShift`, `FluxCD` | `List all available FluxCD Helmreleases`, `Fetch All FluxCD Helmrelease Versions`, `Fetch Mismatched FluxCD HelmRelease Version`, `Fetch FluxCD HelmRelease Error Messages` | This codebundle runs a series of tasks to identify potential helm release issues related to Flux managed Helm objects. [Docs](https://docs.runwhen.com/public/v/cli-codecollection/k8s-fluxcd-helm-health) |
| [Kubernetes Image Rollover Check](https://github.com/runwhen-contrib/rw-cli-codecollection/blob/main/codebundles/k8s-imagerollover-check/runbook.robot) | `Kubernetes`, `AKS`, `EKS`, `GKE`, `OpenShift`, `Redis` | `Check Image Rollover Times In Namespace` | This taskset collects info on the age of images in a Kubernetes workspace. [Docs](https://docs.runwhen.com/public/v/cli-codecollection/k8s-imagerollover-check) |
| [Kubernetes Jenkins Healthcheck](https://github.com/runwhen-contrib/rw-cli-codecollection/blob/main/codebundles/k8s-jenkins-healthcheck/runbook.robot) | `Kubernetes`, `AKS`, `EKS`, `GKE`, `OpenShift`, `Jenkins` | `Query The Jenkins Kubernetes Workload HTTP Endpoint`, `Query For Stuck Jenkins Jobs` | This taskset collects information about perstistent volumes and persistent volume claims to validate health or help troubleshoot potential issues. [Docs](https://docs.runwhen.com/public/v/cli-codecollection/k8s-jenkins-healthcheck) |
| [Kubernetes Labeled Pod Count](https://github.com/runwhen-contrib/rw-cli-codecollection/blob/main/codebundles/k8s-labeledpods-healthcheck/sli.robot) | `Kubernetes`, `AKS`, `EKS`, `GKE`, `OpenShift` | `Measure Number of Running Pods with Label` | This codebundle fetches the number of running pods with the set of provided labels, letting you measure the number of running pods. [Docs](https://docs.runwhen.com/public/v/cli-codecollection/k8s-labeledpods-healthcheck) |
| [Kubernetes Namespace Healthcheck](https://github.com/runwhen-contrib/rw-cli-codecollection/blob/main/codebundles/k8s-namespace-healthcheck/sli.robot) | `Kubernetes`, `AKS`, `EKS`, `GKE`, `OpenShift` | `Get Event Count and Score`, `Get Container Restarts and Score`, `Get NotReady Pods`, `Generate Namspace Score` | This SLI uses kubectl to score namespace health. Produces a value between 0 (completely failing thet test) and 1 (fully passing the test). Looks for container restarts, events, and pods not ready. [Docs](https://docs.runwhen.com/public/v/cli-codecollection/k8s-namespace-healthcheck) |
| [Kubernetes Namespace Troubleshoot](https://github.com/runwhen-contrib/rw-cli-codecollection/blob/main/codebundles/k8s-namespace-healthcheck/runbook.robot) | `Kubernetes`, `AKS`, `EKS`, `GKE`, `OpenShift` | `Trace And Troubleshoot Namespace Warning Events And Errors`, `Troubleshoot Unready Pods In Namespace`, `Troubleshoot Workload Status Conditions In Namespace`, `Get Listing Of Resources In Namespace`, `Check For Namespace Event Anomalies`, `Troubleshoot Namespace Services And Application Workloads` | This taskset runs general troubleshooting checks against all applicable objects in a namespace, checks error events, and searches pod logs for error entries. [Docs](https://docs.runwhen.com/public/v/cli-codecollection/k8s-namespace-healthcheck) |
| [Kubernetes Persistent Volume Healthcheck](https://github.com/runwhen-contrib/rw-cli-codecollection/blob/main/codebundles/k8s-pvc-healthcheck/runbook.robot) | `Kubernetes`, `AKS`, `EKS`, `GKE`, `OpenShift` | `Fetch Events for Unhealthy Kubernetes PersistentVolumeClaims`, `List PersistentVolumes in Terminating State`, `List Pods with Attached Volumes and Related PersistentVolume Details`, `Fetch the Storage Utilization for PVC Mounts` | This taskset collects information about storage such as PersistentVolumes and PersistentVolumeClaims to validate health or help troubleshoot potential storage issues. [Docs](https://docs.runwhen.com/public/v/cli-codecollection/k8s-pvc-healthcheck) |
| [Kubernetes Pod Resources Scan](https://github.com/runwhen-contrib/rw-cli-codecollection/blob/main/codebundles/k8s-podresources-health/runbook.robot) | `Kubernetes`, `AKS`, `EKS`, `GKE`, `OpenShift` | `Scan Labeled Pods and Show All Containers Without Resource Limit or Resource Requests Set`, `Get Labeled Container Top Info` | Inspects the resources provisioned for a given set of pods, selected by their labels and raises issues if no resources were specified. [Docs](https://docs.runwhen.com/public/v/cli-codecollection/k8s-podresources-health) |
| [Kubernetes Postgres Triage](https://github.com/runwhen-contrib/rw-cli-codecollection/blob/main/codebundles/k8s-postgres-triage/runbook.robot) | `AKS`, `EKS`, `GKE`, `Kubernetes`, `Patroni`, `Postgres` | `Get Standard Postgres Resource Information`, `Describe Postgres Custom Resources`, `Get Postgres Pod Logs & Events`, `Get Postgres Pod Resource Utilization`, `Get Running Postgres Configuration`, `Get Patroni Output`, `Run DB Queries` | Runs multiple Kubernetes and psql commands to report on the health of a postgres cluster. [Docs](https://docs.runwhen.com/public/v/cli-codecollection/k8s-postgres-triage) |
| [Kubernetes Redis Healthcheck](https://github.com/runwhen-contrib/rw-cli-codecollection/blob/main/codebundles/k8s-redis-healthcheck/runbook.robot) | `Kubernetes`, `AKS`, `EKS`, `GKE`, `OpenShift`, `Redis` | `Ping Redis Workload`, `Verify Redis Read Write Operation` | This taskset collects information on your redis workload in your Kubernetes cluster and [Docs](https://docs.runwhen.com/public/v/cli-codecollection/k8s-redis-healthcheck) |
| [Kubernetes StatefulSet Triage](https://github.com/runwhen-contrib/rw-cli-codecollection/blob/main/codebundles/k8s-statefulset-healthcheck/runbook.robot) | `Kubernetes`, `AKS`, `EKS`, `GKE`, `OpenShift` | `Fetch StatefulSet Logs`, `Get Related StatefulSet Events`, `Fetch StatefulSet Manifest Details`, `Check StatefulSet Replicas` | Triages issues related to a StatefulSet and its replicas. [Docs](https://docs.runwhen.com/public/v/cli-codecollection/k8s-statefulset-healthcheck) |
| [Kubernetes Vault Triage](https://github.com/runwhen-contrib/rw-cli-codecollection/blob/main/codebundles/k8s-vault-healthcheck/runbook.robot) | `AKS`, `EKS`, `GKE`, `Kubernetes`, `Vault` | `Fetch Vault CSI Driver Logs`, `Get Vault CSI Driver Warning Events`, `Check Vault CSI Driver Replicas`, `Fetch Vault Logs`, `Get Related Vault Events`, `Fetch Vault StatefulSet Manifest Details`, `Fetch Vault DaemonSet Manifest Details`, `Verify Vault Availability`, `Check Vault StatefulSet Replicas` | A suite of tasks that can be used to triage potential issues in your vault namespace. [Docs](https://docs.runwhen.com/public/v/cli-codecollection/k8s-vault-healthcheck) |
| [cURL HTTP OK](https://github.com/runwhen-contrib/rw-cli-codecollection/blob/main/codebundles/curl-http-ok/sli.robot) | `Linux macOS Windows HTTP` | `Checking HTTP URL Is Available And Timely` | This taskset uses curl to validate the response code of the endpoint and provides the total time of the request. [Docs](https://docs.runwhen.com/public/v/cli-codecollection/curl-http-ok) |
| [cli-test-taskset](https://github.com/runwhen-contrib/rw-cli-codecollection/blob/main/codebundles/cli-test/runbook.robot) | `cli` | `Run CLI and Parse Output For Issues`, `Exec Test`, `Local Process Test` | This taskset smoketests the CLI codebundle setup and run process [Docs](https://docs.runwhen.com/public/v/cli-codecollection/cli-test) |
| [cmd-test-taskset](https://github.com/runwhen-contrib/rw-cli-codecollection/blob/main/codebundles/cmd-test/runbook.robot) | `cmd` | `Run CLI Command` | This taskset smoketests the CLI codebundle setup and run process by running a bare command [Docs](https://docs.runwhen.com/public/v/cli-codecollection/cmd-test) |

