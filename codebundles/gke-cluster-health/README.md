## 🚀 Running & Extending the Suite

1. **Set variables / secrets**  
   Provide a service‑account key as `gcp_credentials_json` and define `GCP_PROJECT_ID`.  
   *(Optional)* Tweak `CRITICAL_NAMESPACES`, or any of the Python tunables above.

2. **Execute the Robot Framework suite**  
   The **Suite Setup** authenticates with `gcloud`, exports a consolidated `env`, and every task (`sa_check.sh`, `gcp_recommendations.sh`, `cluster_health.sh`, `quota_check.sh`, `gke_node_size.py`) runs in that context.

3. **What each task does**

   | Task | Checks | Key Outputs |
   |------|--------|-------------|
   | *Identify GKE Service Account Issues* | Missing IAM roles on cluster SAs. | `issues.json` → grouped RW Issues |
   | *Fetch GKE Recommendations* | Recommender‑API tips for clusters. | `recommendations_report.txt`, `recommendations_issues.json` |
   | *Fetch GKE Cluster Health* | CrashLoopBackOff pods & node utilisation via `kubectl`. | `cluster_health_report.txt`, `cluster_health_issues.json` |
   | *Check Quota Autoscaling Issues* | Regional quota blocking node‑pool scale‑out. | `region_quota_report.txt`, `region_quota_issues.json` |
   | *Validate GKE Node Sizes* | **`gke_node_size.py`** – decides “🔄 Reschedule” vs “🆕 Use node X”; groups overloaded nodes per cluster. | CLI stdout embedded in report, JSON issues in `node_size_issues.json` |

4. **Issue creation logic**  
   Each task parses its JSON, groups similar findings (e.g. all overloaded nodes in one entry), and submits **RunWhen Issues** with: severity, title, details, next‑steps, and the exact command to reproduce.

5. **Customisation paths**  
   * Adjust the tunables table.  
   * Swap shell helpers with your own (just emit compatible JSON).  
   * Add more environment vars to `env` for specialised tooling (e.g. custom `KUBECONFIG`).  

With one run you get a comprehensive, read‑only audit covering IAM gaps, GCP recommendations, pod/node health, quota risks, and right‑sizing guidance for every GKE cluster in your project.
