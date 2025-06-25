# GitHub Actions Log Access Troubleshooting

## Issue: "No logs available for this step"

If you're seeing "No logs available for this step" in your workflow failure reports, this means the GitHub token doesn't have sufficient permissions to access GitHub Actions logs.

## Root Cause

GitHub Actions logs require the **`actions:read`** permission, which may not be available to your `GITHUB_TOKEN` due to:

1. **Restricted token permissions** - Repository/organization has restricted default permissions
2. **Missing scope** - Token lacks the `actions:read` scope
3. **Private repository restrictions** - Additional restrictions on private repos

## Solutions

### Option 1: Check Current Token Permissions

Run the diagnostic script to see what permissions your token has:

```bash
# Run the diagnostic
./diagnose_token_permissions.sh
```

This will test:
- Basic authentication
- Token scopes
- Repository access
- Workflow runs access
- Jobs access
- **Log access** (the key test)

### Option 2: Use Enhanced Token (Recommended)

Create a **Personal Access Token** with the required scopes:

1. Go to GitHub Settings → Developer settings → Personal access tokens
2. Create a new token with these scopes:
   - `repo` (full repository access)
   - `actions:read` (read access to Actions)
   - `read:org` (if monitoring organizations)

3. Replace `GITHUB_TOKEN` with your new token in the workflow configuration

### Option 3: Enable Repository Permissions

If using the default `GITHUB_TOKEN`, ensure your repository has the right permissions:

1. Go to Repository Settings → Actions → General
2. Under "Workflow permissions", select **"Read and write permissions"**
3. Or add explicit permissions to your workflow file:

```yaml
permissions:
  actions: read
  contents: read
```

### Option 4: Use the Fallback Script

The enhanced script `check_workflow_failures_fallback.sh` gracefully handles missing log permissions:

- **Detects** when log access fails
- **Provides** detailed error information without logs
- **Suggests** next steps for troubleshooting
- **Falls back** to available information

## Verification

After implementing a solution, verify it works:

1. **Run the diagnostic script** - should show "✓ Log access successful!"
2. **Check workflow failure reports** - should show actual log content instead of "No logs available"

## Expected Results After Fix

Instead of:
```
--- FAILED STEP: Run tests (Step #3) ---
No logs available for this step.
```

You should see:
```
--- FAILED STEP: Run tests (Step #3) ---

=== Error Pattern: failed ===
45:npm ERR! Test failed.  See above for more details.
46:npm ERR! A complete log of this run can be found in:
47:npm ERR!     /home/runner/.npm/_logs/2024-01-15T10_30_45_123Z-debug.log
48:Error: Process completed with exit code 1.
```

## Configuration Options

The fallback script supports these environment variables:

- `ENABLE_LOG_EXTRACTION=true` - Enable/disable log extraction attempts
- `MAX_LOG_LINES_PER_STEP=50` - Maximum log lines to extract per step
- `LOG_CONTEXT_LINES=10` - Lines of context around each error

## Still Having Issues?

If you're still seeing "No logs available" after trying these solutions:

1. **Check token expiration** - Ensure your token hasn't expired
2. **Verify repository access** - Confirm the token can access the specific repositories
3. **Test with a different repository** - Some repos may have additional restrictions
4. **Check log retention** - Very old workflow logs may have been deleted

## Alternative: Manual Log Review

As a last resort, you can always view logs manually:
- Go to the GitHub repository
- Navigate to Actions tab
- Click on the failed workflow run
- Review logs in the web interface

The failure report will include direct links to the failed runs for manual review. 