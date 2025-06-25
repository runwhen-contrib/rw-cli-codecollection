# Enhanced Pipeline Failure Analysis

## What's Been Improved

The pipeline failure checks now grab **actual log content** around the failure points, not just the step names.

## Before vs After

### Before (Old Behavior)
```
Workflow Failed: deploy-app (Run #123)
Job: build (failure)
Failed steps: Run tests, Deploy to staging

Failure Details:
No detailed failure information available. Check the workflow logs manually.
```

### After (Enhanced Behavior)
```
Workflow Failed: deploy-app (Run #123)

=== JOB: build (Status: failure) ===

--- FAILED STEP: Run tests (Step #3) ---

=== Error Pattern: failed ===
45:npm ERR! Test failed.  See above for more details.
46:npm ERR! A complete log of this run can be found in:
47:npm ERR!     /home/runner/.npm/_logs/2024-01-15T10_30_45_123Z-debug.log
48:##[error]Process completed with exit code 1.

--- FAILED STEP: Deploy to staging (Step #5) ---

=== Error Pattern: connection refused ===
23:Error: connect ECONNREFUSED 10.0.0.1:443
24:    at TCPConnectWrap.afterConnect [as oncomplete] (net.js:1146:16)
25:##[error]Unable to connect to staging environment
26:##[error]Process completed with exit code 1.
```

## Key Features

### 1. **Smart Error Detection**
Searches for common failure patterns:
- `error`, `failed`, `failure`, `exception`
- `fatal`, `panic`, `abort`
- `timeout`, `killed`
- `exit code 1-9`
- `connection refused`, `network unreachable`
- `command not found`, `permission denied`

### 2. **Context Extraction**
- Gets **±10 lines** around each error pattern
- Shows **line numbers** for easy reference
- Falls back to **last 50 lines** if no patterns found

### 3. **Rate Limit Protection**
- Limits to **3 workflows per repository**
- **0.5 second delay** between API calls
- Protects against GitHub API rate limits

### 4. **Structured Output**
- Clear job and step organization
- Multiple error patterns per failure
- Actual log content with context

## Configuration Options

You can customize the log extraction behavior:

```bash
# Maximum lines to extract per step (default: 50)
export MAX_LOG_LINES_PER_STEP=100

# Context lines around each error (default: 10)
export LOG_CONTEXT_LINES=15
```

## Performance Impact

- **Moderate increase** in API calls (fetches job logs)
- **Rate limited** to protect against GitHub limits
- **Selective analysis** - only top 3 failures per repo
- **Cached results** - logs fetched once per job

## Usage

The enhanced functionality is **automatically enabled** in the existing workflow failure checks. No configuration changes needed!

## Example Use Cases

### Failed Tests
```
=== Error Pattern: failed ===
156:  ✓ should authenticate user
157:  ✗ should handle invalid credentials
158:    AssertionError: expected 401 to equal 200
159:      at test/auth.test.js:42:28
160:##[error]Test suite failed
```

### Deployment Issues
```
=== Error Pattern: connection refused ===
34:kubectl apply -f deployment.yaml
35:error: unable to connect to server: dial tcp 10.0.0.1:6443: connection refused
36:##[error]Deployment failed - cluster unreachable
```

### Build Failures
```
=== Error Pattern: exit code 1 ===
78:go build -o app main.go
79:main.go:25:2: undefined: fmt.PrintF
80:##[error]Process completed with exit code 2
```

This enhancement provides **actionable intelligence** instead of just "something failed"! 