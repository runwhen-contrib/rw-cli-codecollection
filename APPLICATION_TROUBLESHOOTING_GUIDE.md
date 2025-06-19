# Azure DevOps Application Troubleshooting Guide

## Overview

When an application is failing or crashing, it's crucial to systematically investigate potential root causes across the Azure DevOps environment. This guide outlines how to use the three health check bundles to determine what might be causing application issues.

## Troubleshooting Workflow

### 1. **Azure DevOps Repository Health** - Start Here for Code-Related Issues

**Purpose**: Analyze the specific repository containing your failing application to identify recent changes and code-related issues.

#### Key Tasks for Application Troubleshooting:

**🔍 Investigate Recent Code Changes**
- **What it does**: Analyzes commits, releases, and code changes in the last 7 days (configurable)
- **Helps identify**: 
  - Emergency commits or rollbacks that might indicate existing problems
  - Configuration changes that could cause runtime issues
  - Large commits that may have introduced multiple issues
  - High-frequency commits indicating panic fixes
- **When to use**: Always run this first when applications start failing

**🔍 Analyze Pipeline Failures**
- **What it does**: Reviews recent CI/CD pipeline failures for the repository
- **Helps identify**:
  - Deployment pipeline failures that prevent fixes from reaching production
  - Test failures indicating code quality issues
  - Build failures preventing new deployments
  - Patterns in failures that correlate with application issues
- **When to use**: When you suspect CI/CD issues are preventing proper deployments

**🔍 Check Repository Security Configuration**
- **What it does**: Reviews branch policies and security settings
- **Helps identify**: Misconfigurations that might allow problematic code to be deployed
- **When to use**: When investigating if proper approval processes were bypassed

**🔍 Analyze Code Quality**
- **What it does**: Reviews code quality metrics and technical debt
- **Helps identify**: Quality issues that might cause runtime problems
- **When to use**: When looking for underlying code issues that might cause instability

### 2. **Azure DevOps Project Health** - Investigate Broader Project Issues

**Purpose**: Examine project-level resources that might be affecting your application.

#### Key Tasks for Application Troubleshooting:

**🔍 Check Agent Pool Availability**
- **What it does**: Monitors build agent health and capacity
- **Helps identify**: Agent issues preventing builds and deployments
- **Application impact**: Failed deployments due to unavailable build agents

**🔍 Check for Failed Pipelines Across Projects**
- **What it does**: Identifies pipeline failures across the entire project
- **Helps identify**: Systemic issues affecting multiple applications
- **Application impact**: Infrastructure or shared resource problems

**🔍 Check for Queued Pipelines**
- **What it does**: Finds pipelines stuck in queue beyond thresholds
- **Helps identify**: Resource contention or agent capacity issues
- **Application impact**: Delayed deployments and fixes

**🔍 Check Service Connection Health**
- **What it does**: Verifies connectivity to external services and Azure resources
- **Helps identify**: Authentication or connectivity issues to dependencies
- **Application impact**: Failed deployments or runtime connectivity issues

### 3. **Azure DevOps Organization Health** - Check Platform-Wide Issues

**Purpose**: Investigate organization-level problems that might be affecting your application.

#### Key Tasks for Application Troubleshooting:

**🔍 Check Service Health Status**
- **What it does**: Tests Azure DevOps platform connectivity and performance
- **Helps identify**: Platform-wide service disruptions
- **Application impact**: Inability to deploy fixes or investigate issues

**🔍 Investigate Platform Issues**
- **What it does**: Analyzes cross-project failure patterns and API performance
- **Helps identify**: Organization-wide problems affecting multiple teams
- **Application impact**: Systemic issues that might affect your application's dependencies

**🔍 Check Organization Policies**
- **What it does**: Reviews organization-level security and compliance policies
- **Helps identify**: Policy changes that might affect application behavior
- **Application impact**: Compliance-related application restrictions or failures

## Recommended Investigation Order

### Phase 1: Immediate Repository Analysis (5-10 minutes)
1. **Azure DevOps Repository Health**:
   - Run "Investigate Recent Code Changes" 
   - Run "Analyze Pipeline Failures"
   - Look for emergency commits, configuration changes, or deployment failures

### Phase 2: Project-Level Investigation (10-15 minutes)
2. **Azure DevOps Project Health**:
   - Run "Check for Failed Pipelines Across Projects"
   - Run "Check Service Connection Health" 
   - Run "Check Agent Pool Availability"

### Phase 3: Organization-Level Issues (5-10 minutes)
3. **Azure DevOps Organization Health**:
   - Run "Check Service Health Status"
   - Run "Investigate Platform Issues"

## Key Indicators to Look For

### 🚨 Critical Issues (Immediate Action Required)
- **Deployment pipeline failures** in the last 24-48 hours
- **Emergency commits or rollbacks** indicating known problems
- **Service connection failures** preventing application connectivity
- **High pipeline failure rates** (>50%) across critical pipelines

### ⚠️ Warning Signs (Investigate Further)
- **High-frequency commits** (>10 per day) indicating reactive fixes
- **Configuration changes** in recent commits
- **Large commits** (>50 files) that might have introduced multiple issues
- **Agent pool capacity issues** preventing timely deployments

### ℹ️ Information Indicators (Context for Investigation)
- **No recent commits** (issues might be external to code)
- **No recent pipeline activity** (manual deployment issues)
- **Last successful deployment timestamp** (reference point for when issues started)

## Common Root Cause Patterns

### Pattern 1: Recent Code Changes
- **Symptoms**: Application started failing after recent commits
- **Investigation**: Recent changes analysis shows risky commits
- **Action**: Review and potentially rollback problematic commits

### Pattern 2: Deployment Pipeline Issues
- **Symptoms**: Application issues correlate with deployment failures
- **Investigation**: Pipeline failure analysis shows deployment problems
- **Action**: Fix pipeline issues and redeploy successful version

### Pattern 3: Infrastructure/Configuration Issues  
- **Symptoms**: No recent code changes but application failing
- **Investigation**: Service connection or external dependency failures
- **Action**: Fix infrastructure or service connection issues

### Pattern 4: Systemic Platform Issues
- **Symptoms**: Multiple applications affected simultaneously
- **Investigation**: Organization health shows platform-wide problems
- **Action**: Wait for platform resolution or implement workarounds

## Environment Variables for Tuning Analysis

### Repository Health Configuration
- `ANALYSIS_DAYS`: Days to look back for changes (default: 7)
- `REPO_SIZE_THRESHOLD_MB`: Repository size threshold for performance issues (default: 500)
- `MIN_CODE_COVERAGE`: Minimum code coverage threshold (default: 80)

### Project Health Configuration  
- `DURATION_THRESHOLD`: Long-running pipeline threshold (default: 60m)
- `QUEUE_THRESHOLD`: Queued pipeline threshold (default: 30m)

### Organization Health Configuration
- `AGENT_UTILIZATION_THRESHOLD`: Agent utilization threshold (default: 80%)
- `LICENSE_UTILIZATION_THRESHOLD`: License utilization threshold (default: 90%)

## Quick Start Checklist

When an application fails, run these tasks in order:

- [ ] **Repository Health**: Investigate Recent Code Changes
- [ ] **Repository Health**: Analyze Pipeline Failures  
- [ ] **Project Health**: Check for Failed Pipelines Across Projects
- [ ] **Project Health**: Check Service Connection Health
- [ ] **Organization Health**: Check Service Health Status

This systematic approach will quickly identify whether your application issues are related to:
- Recent code changes
- CI/CD pipeline problems  
- Project-level resource issues
- Organization-wide platform problems

## Next Steps After Investigation

Based on your findings:

1. **Code Issues Found**: Review and rollback problematic commits, fix code quality issues
2. **Pipeline Issues Found**: Fix deployment pipelines, resolve agent/infrastructure problems  
3. **Service Issues Found**: Fix service connections, resolve authentication issues
4. **Platform Issues Found**: Contact Azure DevOps support or wait for service restoration

Remember: The goal is to quickly identify the most likely root cause and take corrective action to restore application functionality. 