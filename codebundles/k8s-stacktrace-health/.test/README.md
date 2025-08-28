# Testing k8s-stacktrace-health Codebundle

This directory contains test configuration and tools for the k8s-stacktrace-health codebundle. This codebundle supports deployments, statefulsets, and daemonsets.

## Prerequisites

- Docker installed and running
- Access to a Kubernetes cluster
- Valid kubeconfig file
- Task (taskfile.dev) installed

## Quick Start

1. **Place your kubeconfig file**:
   ```bash
   cp ~/.kube/config kubeconfig.secret
   ```

2. **Run the test**:
   ```bash
   task
   ```

3. **Review generated configurations**:
   ```bash
   ls -la output/workspaces/*/slxs/
   ```

## Test Configuration

### workspaceInfo.yaml
- **Workspace Name**: `stacktrace-health-test`
- **Target Namespaces**: `online-boutique`, `default`, `kube-system`, `monitoring`
- **Codebundle**: `k8s-stacktrace-health`
- **Supported Workloads**: Deployments, StatefulSets, DaemonSets

### Generated Resources
The test will generate:
- **SLX**: Service Level X definition for stacktrace health monitoring
- **SLI**: Service Level Indicator for stacktrace detection
- **Runbook**: Troubleshooting tasks for stacktrace analysis
- **Workflow**: Automated response workflows

## Available Tasks

- `task` - Generate workspaceInfo and run discovery
- `task clean` - Clean up test outputs
- `task upload-slxs` - Upload SLXs to RunWhen Platform (requires RW_* env vars)
- `task delete-slxs` - Delete SLXs from RunWhen Platform

## Testing Stacktrace Detection

To test the stacktrace detection functionality:

1. **Deploy test workloads** that generate stacktraces:
   - Deployment with application errors
   - StatefulSet with database connection issues
   - DaemonSet with node-level problems
2. **Run the discovery** to create monitoring resources for all workload types
3. **Verify SLI detection** by checking the generated configurations for each workload type
4. **Test runbook execution** manually or through the platform across different workload types

## Environment Variables for Platform Integration

For uploading to RunWhen Platform:
```bash
export RW_WORKSPACE="your-workspace"
export RW_API_URL="your-api-url"
export RW_PAT="your-personal-access-token"
```

## Expected Outputs

### SLI Configuration
- Monitors stacktraces every 5 minutes across all workload types
- Alerts when stacktraces are detected in any supported workload
- Optimized log limits for performance
- Automatically detects workload type (deployment/statefulset/daemonset)

### Runbook Configuration  
- Comprehensive stacktrace analysis across all workload types
- Multi-container support for complex workloads
- Detailed troubleshooting steps tailored to workload type
- Supports deployments, statefulsets, and daemonsets

### Workflow Configuration
- Automatic triggering on SLI alerts
- Integration with Eager Edgar persona
- 20-minute investigation sessions

## Troubleshooting

- **Container fails to start**: Check Docker daemon and permissions
- **No resources generated**: Verify kubeconfig and cluster access
- **Upload fails**: Check RW_* environment variables and permissions
- **Discovery errors**: Review container logs with `docker logs RunWhenLocal`
- **Workload type issues**: Ensure test workloads include deployments, statefulsets, and daemonsets