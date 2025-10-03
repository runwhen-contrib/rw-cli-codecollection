# PostgreSQL Operations CodeBundle

## Overview

This codebundle provides **operational remediation capabilities** for PostgreSQL clusters running in Kubernetes. It focuses exclusively on **performing actions** to fix issues identified by monitoring tools, with the primary capability being **reinitializing failed cluster members**. It supports both CrunchyDB and Zalando PostgreSQL operators.

**Note**: This codebundle is designed to work alongside `k8s-postgres-healthcheck` for complete PostgreSQL cluster management - healthcheck identifies issues, operations fixes them.

## Key Features

### 🔧 Primary Operations
- **Failed Member Reinitialize**: Core capability to recover corrupted or failed cluster members
- **Emergency Failover**: Promote replicas to master during outages
- **Cluster Scaling**: Add or remove cluster members for capacity management
- **Rolling Restart**: Safe maintenance operations across all cluster members
- **Multi-Operator Support**: Works with both CrunchyDB and Zalando PostgreSQL operators

### 📊 Operational Focus
- **Action-Oriented**: All tasks perform cluster modifications (read-write operations)
- **Remediation-Focused**: Designed to fix issues, not just detect them
- **Robot Framework Integration**: Full automation for operational workflows
- **Comprehensive Reporting**: Detailed operation logs and success/failure tracking

### 🚀 Advanced Capabilities
- **Smart Recovery Methods**: Uses patronictl reinit with pod recreation fallback
- **Safety Checks**: Validates operations and monitors recovery progress
- **Error Handling**: Comprehensive issue tracking with severity levels
- **Post-Operation Verification**: Confirms successful completion of operations

## Scripts

### `reinitialize_cluster_member.sh`
**Primary script for failed member recovery**

```bash
# Automatic detection and reinitialize of failed members
bash reinitialize_cluster_member.sh
```

**Features:**
- Detects failed cluster members using patronictl
- Attempts patronictl reinit first (clean recovery)
- Falls back to pod deletion/recreation if needed
- Verifies recovery success and cluster health
- Comprehensive error handling and reporting

### `cluster_operations.sh`
**Comprehensive cluster management operations**

```bash
# Get cluster overview (default)
OPERATION=overview bash cluster_operations.sh

# Perform emergency failover to specific member
OPERATION=failover TARGET_MEMBER=cluster-member-2 bash cluster_operations.sh

# Scale cluster to 5 members
OPERATION=scale REPLICA_COUNT=5 bash cluster_operations.sh

# Perform rolling restart for maintenance
OPERATION=restart bash cluster_operations.sh

# Get cluster overview (read-only, mainly for verification)
OPERATION=overview bash cluster_operations.sh
```

## Supported Operators

### CrunchyDB PostgreSQL Operator
- **Resource Type**: `postgresclusters.postgres-operator.crunchydata.com`
- **Container Name**: `database`
- **Pod Labels**: `postgres-operator.crunchydata.com/cluster=<name>`
- **Master Label**: `postgres-operator.crunchydata.com/role=master`

### Zalando PostgreSQL Operator
- **Resource Type**: `postgresqls.acid.zalan.do`
- **Container Name**: `postgres`
- **Pod Labels**: `application=spilo,cluster-name=<name>`
- **Master Label**: `spilo-role=master`

## Environment Variables

| Variable | Description | Example | Required |
|----------|-------------|---------|----------|
| `KUBERNETES_DISTRIBUTION_BINARY` | Kubernetes CLI binary | `kubectl` | Yes |
| `CONTEXT` | Kubernetes context | `my-cluster` | Yes |
| `NAMESPACE` | Target namespace | `postgres-system` | Yes |
| `OBJECT_NAME` | Cluster name | `my-postgres-cluster` | Yes |
| `OBJECT_API_VERSION` | Cluster API version | `postgres-operator.crunchydata.com/v1beta1` | Yes |
| `DATABASE_CONTAINER` | Database container name | `database` or `postgres` | Yes |
| `OPERATION` | Operation type | `overview`, `failover`, `scale`, `restart` | No |
| `TARGET_MEMBER` | Target for failover | `cluster-member-2` | No |
| `REPLICA_COUNT` | Desired replica count | `3` | No |

## Robot Framework Integration

### Runbook Tasks
1. **Reinitialize Failed PostgreSQL Cluster Members for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`** `[access:read-write]`
2. **Perform PostgreSQL Cluster Failover Operation for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`** `[access:read-write]`
3. **Scale PostgreSQL Cluster Replicas for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`** `[access:read-write]`
4. **Restart PostgreSQL Cluster with Rolling Update for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`** `[access:read-write]`
5. **Verify Cluster Recovery and Generate Summary for Cluster `${OBJECT_NAME}` in Namespace `${NAMESPACE}`** `[access:read-write]`

**Note**: All tasks require `access:read-write` permissions as they perform cluster operations. Task names include cluster and namespace variables for clarity and consistency with healthcheck tasks.

### Integration with k8s-postgres-healthcheck
This codebundle is designed to work alongside the `k8s-postgres-healthcheck` codebundle for complete PostgreSQL cluster management:

| **Aspect** | **k8s-postgres-healthcheck** | **k8s-postgres-operations** |
|------------|------------------------------|------------------------------|
| **Purpose** | 🔍 **Detect & Diagnose** | ⚡ **Act & Remediate** |
| **Access Level** | `access:read-only` | `access:read-write` |
| **Focus** | Comprehensive monitoring & diagnostics | Targeted operational remediation |
| **When to Use** | Regular health checks & issue detection | When problems need to be fixed |
| **Capabilities** | Patroni status, replication lag, config analysis | Member reinitialize, failover, scaling, restarts |

**Workflow**: Healthcheck identifies issues → Issues reference specific operations tasks → Operations codebundle provides remediation

## Usage Examples

### Emergency Member Recovery
```bash
# Set environment variables
export KUBERNETES_DISTRIBUTION_BINARY=kubectl
export CONTEXT=my-cluster
export NAMESPACE=postgres-system
export OBJECT_NAME=my-postgres-cluster
export OBJECT_API_VERSION=postgres-operator.crunchydata.com/v1beta1
export DATABASE_CONTAINER=database

# Automatically detect and reinitialize failed members
bash reinitialize_cluster_member.sh
```

### Emergency Failover Operation
```bash
# Promote specific replica to master during outage
export OPERATION=failover
export TARGET_MEMBER=my-postgres-cluster-2
bash cluster_operations.sh
```

### Capacity Management
```bash
# Scale cluster up for increased load
export OPERATION=scale
export REPLICA_COUNT=5
bash cluster_operations.sh
```

### Maintenance Operations
```bash
# Rolling restart for configuration updates
export OPERATION=restart
bash cluster_operations.sh
```

## Output Files

- **`reinitialize_report.out`**: Detailed reinitialize operation results
- **`cluster_operations_report.out`**: Comprehensive cluster operation logs

## Error Handling

The codebundle provides comprehensive error handling with:
- **Severity Levels**: `error`, `warning`, `info`
- **JSON Issue Tracking**: Structured error reporting
- **Graceful Degradation**: Fallback methods when primary operations fail
- **Detailed Logging**: Timestamped operation logs

## Prerequisites

- Kubernetes cluster with PostgreSQL operator (CrunchyDB or Zalando)
- `kubectl` or `oc` CLI access
- `jq` for JSON processing
- `patronictl` available in PostgreSQL pods
- Appropriate RBAC permissions for cluster operations

## Troubleshooting Operations

### Common Operational Issues

1. **Reinitialize Operation Fails**
   - **Check cluster connectivity**: `kubectl exec <pod> -c <container> -- patronictl list`
   - **Verify network access** between cluster members
   - **Check storage space** and PVC availability
   - **Review pod logs**: `kubectl logs <pod> -c <container>`

2. **Failover Operation Fails**
   - **Verify target member is healthy**: Check patronictl status
   - **Ensure quorum availability**: At least 2 members must be accessible
   - **Check network partitions**: Verify inter-pod connectivity

3. **Scaling Operation Fails**
   - **Resource constraints**: Check node capacity and resource quotas
   - **Storage provisioning**: Verify PVC creation for new members
   - **Operator health**: Check PostgreSQL operator logs

4. **Permission Errors**
   - **RBAC permissions**: Verify service account has pod/statefulset modification rights
   - **Operator access**: Check if operator can manage cluster resources

### Manual Recovery Steps

If automated operations fail, use these manual steps:

1. **Manual Member Reinitialize**:
   ```bash
   kubectl exec <healthy-pod> -c <container> -- patronictl reinit <cluster> <failed-member> --force
   ```

2. **Manual Failover**:
   ```bash
   kubectl exec <current-master> -c <container> -- patronictl switchover <cluster> --candidate <target-member> --force
   ```

3. **Manual Pod Recreation**:
   ```bash
   kubectl delete pod <failed-pod> -n <namespace>
   ```

4. **Check Operation Results**:
   ```bash
   kubectl exec <pod> -c <container> -- patronictl list
   ```

## Design Principles

This codebundle follows these key principles:

### 🎯 **Operations-Only Focus**
- **No Monitoring**: Relies on `k8s-postgres-healthcheck` for issue detection
- **Action-Oriented**: Every task performs cluster modifications
- **Remediation-Focused**: Designed to fix problems, not find them

### 🔒 **Safety First**
- **Validation**: Checks cluster state before operations
- **Verification**: Confirms successful completion
- **Fallback Methods**: Multiple approaches for each operation
- **Comprehensive Logging**: Detailed operation tracking

### 🔄 **Operator Agnostic**
- **CrunchyDB Support**: Native integration with Crunchy PostgreSQL Operator
- **Zalando Support**: Full compatibility with Zalando PostgreSQL Operator
- **Unified Interface**: Same operations work across both operators

## Contributing

When extending this codebundle:
1. **Maintain operational focus** - only add tasks that perform actions
2. **Support both operators** - ensure CrunchyDB and Zalando compatibility
3. **Add comprehensive error handling** with JSON-formatted issue tracking
4. **Include verification steps** to confirm operation success
5. **Update documentation** with clear usage examples
6. **Test failure scenarios** to ensure robust recovery methods
7. **Follow existing patterns** for logging and reporting
