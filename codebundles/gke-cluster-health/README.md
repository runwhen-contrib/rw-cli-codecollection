# GKE Cluster Health

This codebundle performs comprehensive health checking for Google Kubernetes Engine (GKE) clusters, including node pool analysis, instance group evaluation, and resource optimization recommendations.


### Enhanced Instance Group Analysis
- **Individual Instance Evaluation**: Now evaluates each instance within instance groups, not just group-level operations
- **Instance State Monitoring**: Checks for `RUNNING`, `TERMINATED`, `FAILED`, and transitional states  
- **Missing Instance Detection**: Cross-validates Kubernetes nodes against compute instances to catch missing or orphaned instances
- **Comprehensive Event Tracking**: Monitors both instance group and individual instance operations for failures

### Improved Node Pool Health Monitoring
- **Instance-Level Operations**: Tracks failed operations on individual instances (preemptions, quota failures, etc.)
- **Node Readiness Validation**: Checks node conditions and taints that affect scheduling
- **Cross-Platform Validation**: Ensures all expected instances from node pools are properly integrated into Kubernetes
- **Enhanced Error Detection**: Better pattern matching for quota exhaustion, regional capacity issues, and permission problems

### Node Sizing Analysis Improvements
- **Better Node Discovery**: Enhanced validation that all nodes are being properly evaluated
- **Unscheduled Pod Detection**: Identifies pods that cannot be scheduled due to resource constraints
- **Node Pool Validation**: Cross-checks expected vs actual node counts to detect provisioning failures
- **Resource Pressure Monitoring**: Improved detection of nodes under memory/disk pressure

## Tasks

### Identify GKE Service Account Issues
Checks for IAM Service Account issues that can affect cluster functionality.

### Fetch GKE Recommendations  
Retrieves and summarizes GCP Recommendations for GKE Clusters.

### Fetch GKE Cluster Health
Performs comprehensive health checking including:
- Pod health and crash loop detection
- Node utilization analysis  
- Resource availability assessment

### Check for Quota Related Autoscaling Issues
Ensures GKE Autoscaling will not be blocked by quota constraints.

### Validate GKE Node Sizes
**Enhanced with comprehensive instance evaluation:**
- Analyzes live pod requests/limits and node usage
- Proposes suitable GKE node machine types
- **NEW**: Validates all instances are accounted for and healthy
- **NEW**: Detects missing instances that should be part of the cluster
- **NEW**: Cross-validates node pool expectations vs reality

### Fetch GKE Cluster Operations
Fetches GKE Operations and identifies stuck or failed tasks.

### Check Node Pool Health ⭐ **SIGNIFICANTLY ENHANCED**
**Now includes comprehensive instance-level analysis and log retrieval:**
- **Individual Instance Health**: Evaluates each instance in every instance group
- **Instance State Monitoring**: Tracks `RUNNING`, `TERMINATED`, `PROVISIONING` states
- **Missing Instance Detection**: Identifies instances that failed to join the cluster
- **Operation History Analysis**: Reviews recent operations on both groups and individual instances  
- **Quota Exhaustion Detection**: Enhanced patterns for identifying resource constraints
- **Kubernetes Event Correlation**: Links compute instance issues with K8s node events
- **Cross-Platform Validation**: Ensures compute instances and K8s nodes are properly synchronized
- **🆕 Managed Instance Group Log Analysis**: Retrieves and analyzes MIG logs for resource exhaustion, quota issues, and disk attachment errors
- **🆕 Individual Instance Serial Console Logs**: Analyzes instance boot logs for memory exhaustion, disk space issues, and kernel panics
- **🆕 Cloud Logging Integration**: Retrieves GCP Cloud Logging entries for instances to catch storage, metadata, and Kubernetes service failures
- **🆕 MIG Manager Activity Logs**: Analyzes autoscaling operations, quota failures, and regional capacity exhaustion
- **🆕 GKE Autoscaler Logs**: Examines cluster autoscaler logs for scaling failures and node group readiness issues

## Key Improvements

### Comprehensive Managed Instance Log Analysis 🆕
The enhanced implementation now retrieves and analyzes actual managed instance logs to surface critical issues:

#### **Managed Instance Group Logs**
- **Resource Quota Exhaustion**: `quota exceeded`, `QUOTA_EXCEEDED`, `resource exhausted`, `ZONE_RESOURCE_POOL_EXHAUSTED`
- **Disk Attachment Failures**: `disk attach failed`, `disk mount failed`, `volume attach error`
- **Network Resource Exhaustion**: `network unavailable`, `subnet exhausted`, `IP allocation failed`
- **Permission Issues**: `permission denied`, `access denied`, `unauthorized`
- **Instance Provisioning Failures**: `instance creation failed`, `instance start failed`, `provisioning failed`

#### **Individual Instance Serial Console Logs**
- **Memory Exhaustion**: `Out of memory`, `OOM`, `memory allocation failed`
- **Disk Space Issues**: `No space left`, `disk full`, `filesystem full`
- **System Failures**: `kernel panic`, `system panic`, `fatal system error`
- **Network Connectivity**: `network unreachable`, `DNS resolution failed`, `connection timeout`

#### **Cloud Logging Integration**
- **Storage Attachment**: `disk attachment failed`, `volume mount error`, `storage unavailable`
- **Metadata Service**: `metadata server unreachable`, `metadata service failed`
- **Kubernetes Services**: `kubelet failed start`, `kubernetes service failed`, `container runtime error`

#### **MIG Manager Activity Analysis**
- **Autoscaling Failures**: Analyzes `resize`, `recreateInstances`, and other MIG operations
- **Quota Type Identification**: Identifies specific quota types (CPU, Disk, IP Address, Instance)
- **Regional Capacity Issues**: Detects `ZONE_RESOURCE_POOL_EXHAUSTED` and capacity constraints
- **Resource State Problems**: `INVALID_RESOURCE_STATE`, `RESOURCE_NOT_FOUND`, `PRECONDITION_FAILED`

#### **GKE Autoscaler Log Analysis**
- **Scale-up Failures**: `scale up failed`, `failed to scale up`, `couldn't scale up`
- **Node Group Readiness**: `node group not ready`, `nodegroup not ready`, `instance group not ready`
- **Resource Constraints**: `quota exceeded`, `resource exhausted`, `capacity exceeded`

### Fixed Missing Instance Detection
The previous implementation only checked instance group operations but missed individual instance evaluation. Now the system:

1. **Lists all instances** in each instance group using `gcloud compute instance-groups managed list-instances`
2. **Evaluates individual instance health** including status, current actions, and recent operations
3. **Cross-validates** Kubernetes nodes against compute instances to catch missing integrations  
4. **Tracks instance-level operations** to detect preemptions, quota failures, and other critical events
5. **Provides detailed reporting** on instance health with actionable remediation steps

### Enhanced Error Detection
- **Quota Exhaustion**: Better detection of `ZONE_RESOURCE_POOL_EXHAUSTED` and quota-related failures
- **Instance Preemptions**: Specific handling for preempted instances with appropriate recommendations
- **Node Integration Failures**: Identifies running compute instances that haven't joined Kubernetes
- **Orphaned Resources**: Detects both orphaned K8s nodes and stranded compute instances

This ensures that critical events affecting instance groups are no longer missed, providing comprehensive visibility into cluster health and capacity issues.

## 🚀 Running & Extending the Suite

1. **Set variables / secrets**  
   Provide a service‑account key as `gcp_credentials_json` and define `GCP_PROJECT_ID`.  
   *(Optional)* Tweak `CRITICAL_NAMESPACES`, `NODE_HEALTH_LOOKBACK_HOURS`, or any of the Python tunables above.

2. **Execute the Robot Framework suite**  
   The **Suite Setup** authenticates with `gcloud`, exports a consolidated `env`, and every task (`sa_check.sh`, `gcp_recommendations.sh`, `cluster_health.sh`, `quota_check.sh`, `gke_node_size.py`, `node_pool_health.sh`) runs in that context.

3. **What each task does**

   | Task | Checks | Key Outputs |
   |------|--------|-------------|
   | *Identify GKE Service Account Issues* | Missing IAM roles on cluster SAs. | `issues.json` → grouped RW Issues |
   | *Fetch GKE Recommendations* | Recommender‑API tips for clusters. | `recommendations_report.txt`, `recommendations_issues.json` |
   | *Fetch GKE Cluster Health* | CrashLoopBackOff pods & node utilisation via `kubectl`. | `cluster_health_report.txt`, `cluster_health_issues.json` |
   | *Check Quota Autoscaling Issues* | Regional quota blocking node‑pool scale‑out. | `region_quota_report.txt`, `region_quota_issues.json` |
   | *Validate GKE Node Sizes* | **`gke_node_size.py`** – decides "🔄 Reschedule" vs "🆕 Use node X"; groups overloaded nodes per cluster. | CLI stdout embedded in report, JSON issues in `node_size_issues.json` |
   | *Check Comprehensive Node Pool Health* | **`node_pool_health.sh`** – surfaces hard-to-find issues like region exhaustion, quota blocking, instance group failures, and Kubernetes node events. | `node_pool_health_report.txt`, `node_pool_health_issues.json` |

4. **Issue creation logic**  
   Each task parses its JSON, groups similar findings (e.g. all overloaded nodes in one entry), and submits **RunWhen Issues** with: severity, title, details, next‑steps, and the exact command to reproduce.

5. **Key enhancements for node health**  
   The new comprehensive node pool health check specifically targets issues that are traditionally hard to surface:
   * **Region exhaustion errors** – Detects `ZONE_RESOURCE_POOL_EXHAUSTED` and similar capacity issues
   * **Quota blocking** – Identifies quota exceeded errors preventing node scaling 
   * **Instance group failures** – Examines compute operations for failed scaling attempts
   * **Kubernetes node events** – Analyzes node-related warning events for resource pressure
   * **Node pool status issues** – Checks for non-running node pools indicating scaling problems

6. **Customisation paths**  
   * Adjust the tunables table, including `NODE_HEALTH_LOOKBACK_HOURS` for event analysis timeframe.  
   * Swap shell helpers with your own (just emit compatible JSON).  
   * Add more environment vars to `env` for specialised tooling (e.g. custom `KUBECONFIG`).  

With one run you get a comprehensive, read‑only audit covering IAM gaps, GCP recommendations, pod/node health, quota risks, right‑sizing guidance, and **critical node pool issues like region exhaustion** for every GKE cluster in your project.
