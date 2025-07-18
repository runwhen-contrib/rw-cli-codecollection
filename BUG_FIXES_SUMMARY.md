# Bug Fixes Summary

This document outlines 3 critical bugs that were identified and fixed in the RunWhen CLI codebase.

## Bug 1: Variable Name Error in stdout_parser.py

**File**: `libraries/RW/CLI/stdout_parser.py`  
**Lines**: 295 and 315  
**Type**: Logic Error  
**Severity**: High  

### Problem
In the `parse_cli_output_by_line` function, there were references to an undefined variable `variable_value` instead of the correct variable `capture_group_value` in two locations:

1. Line 295: In the `raise_issue_if_contains` condition
2. Line 315: In the `raise_issue_if_ncontains` condition

### Impact
This would cause a `NameError` when the code tries to access `variable_value` which is not defined in the scope, causing the parsing function to fail completely.

### Fix
Changed `variable_value` to `capture_group_value` in both locations to use the correct variable that was defined earlier in the function.

```python
# Before (incorrect)
f"Value of {prefix} ({variable_value}) Contained {query_value}"

# After (correct)
f"Value of {prefix} ({capture_group_value}) Contained {query_value}"
```

## Bug 2: Incorrect Variable Name in cli_utils.py

**File**: `libraries/RW/CLI/cli_utils.py`  
**Line**: 95  
**Type**: Logic Error  
**Severity**: High  

### Problem
In the `to_json` function, the parameter was named `json_data` but the function tried to use `json_str` which was not defined.

### Impact
This would cause a `NameError` when trying to serialize JSON data, making the JSON serialization functionality completely unusable.

### Fix
Changed `json_str` to `json_data` to use the correct parameter name.

```python
# Before (incorrect)
def to_json(json_data: any):
    return json.dumps(json_str)

# After (correct)
def to_json(json_data: any):
    return json.dumps(json_data)
```

## Bug 3: Security Vulnerability in local_process.py

**File**: `libraries/RW/CLI/local_process.py`  
**Lines**: 95-105  
**Type**: Security Vulnerability  
**Severity**: Critical  

### Problem
The script writes secret values to files without proper file permissions. The `chmod` command only sets execute permissions (`u+x`) but doesn't restrict read access to the file owner only. This means secret files could be readable by other users on the system.

### Impact
Secret files containing sensitive information (API keys, passwords, tokens) could be exposed to unauthorized users, potentially leading to security breaches.

### Fix
Added additional permission setting for secret files to ensure they are only readable by the file owner (permission 600).

```python
# Added after the general chmod command
# Set restrictive permissions on secret files to prevent unauthorized access
for s in ds_secrets:
    if s["file"]:
        secret_file_path = os.path.join(final_cwd, s["key"])
        subprocess.run(
            ["chmod", "600", secret_file_path],
            check=False,
            text=True,
            capture_output=True,
            timeout=timeout_seconds
        )
```

## Testing Recommendations

1. **Bug 1 & 2**: Test the JSON parsing and stdout parsing functionality to ensure they work correctly without NameError exceptions.

2. **Bug 3**: Test with secret files to verify that:
   - Secret files are created with proper permissions (600)
   - Other users cannot read the secret files
   - The functionality still works as expected

## Files Modified

1. `libraries/RW/CLI/stdout_parser.py` - Fixed variable name errors
2. `libraries/RW/CLI/cli_utils.py` - Fixed parameter name error  
3. `libraries/RW/CLI/local_process.py` - Added security fix for secret file permissions

## Conclusion

These fixes address critical issues that could cause runtime errors and security vulnerabilities. The changes are minimal and focused, maintaining the existing functionality while fixing the identified problems.