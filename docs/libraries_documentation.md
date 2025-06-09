# RunWhen CodeCollection Libraries Documentation

## Overview

This documentation covers the Python libraries that provide Robot Framework keywords for the RunWhen CodeCollection. These keywords are designed to help you create effective runbooks and SLIs for troubleshooting and monitoring.

**Total Libraries:** 14  
**Total Keywords:** 176

## Getting Started

To use these keywords in your Robot Framework files:

1. Import the library in your Robot Framework file
2. Use the keywords in your test cases or tasks
3. Refer to the examples below for syntax

### Example Robot Framework Usage

```robotframework
*** Settings ***
Library    RW.Core
Library    RW.K8s

*** Tasks ***
Check Pod Status
    ${pods}=    RW.K8s.Get Pods    namespace=default
    RW.Core.Add Pre To Report    Found ${pods} pods
```

## Table of Contents

- [Core Operations](#core-operations)
- [Kubernetes](#kubernetes)
- [File Operations](#file-operations)
- [HTTP/API](#httpapi)
- [Utilities](#utilities)
- [Other](#other)

## Core Operations

### jenkins Library

#### Jenkins.build_logs_analytics

For each job in Jenkins, retrieve up to `history_limit` failed builds,
analyze their logs, and attempt to find common error patterns using fuzzy matching.

Returns a list of dictionaries, each describing:
  - job_name
  - builds_analyzed
  - similarity_score
  - common_error_patterns

Example usage:
| ${analysis_results}= | Build Logs Analytics | ${JENKINS_URL} | ${JENKINS_USERNAME} | ${JENKINS_TOKEN} | 5 |
| FOR  ${analysis}  IN  @{analysis_results} |
|    Log  Job ${analysis['job_name']} has average log similarity ${analysis['similarity_score']}. |
|    Log  Common error patterns: ${analysis['common_error_patterns']} |
| END |

**Arguments:**

- `jenkins_url`
- `jenkins_username`
- `jenkins_token`
- `history_limit`

**Robot Framework Example:**

```robotframework
${jenkins_build_logs_analytics_result}=    Jenkins.build_logs_analytics    https://example.com    example-name    ${jenkins_token}    ...
```

---

#### build_logs_analytics

For each job in Jenkins, retrieve up to `history_limit` failed builds,
analyze their logs, and attempt to find common error patterns using fuzzy matching.

Returns a list of dictionaries, each describing:
  - job_name
  - builds_analyzed
  - similarity_score
  - common_error_patterns

Example usage:
| ${analysis_results}= | Build Logs Analytics | ${JENKINS_URL} | ${JENKINS_USERNAME} | ${JENKINS_TOKEN} | 5 |
| FOR  ${analysis}  IN  @{analysis_results} |
|    Log  Job ${analysis['job_name']} has average log similarity ${analysis['similarity_score']}. |
|    Log  Common error patterns: ${analysis['common_error_patterns']} |
| END |

**Arguments:**

- `jenkins_url`
- `jenkins_username`
- `jenkins_token`
- `history_limit`

**Robot Framework Example:**

```robotframework
${build_logs_analytics_result}=    build_logs_analytics    https://example.com    example-name    ${jenkins_token}    ...
```

---

### k8s_applications Library

#### stacktrace_report_data

**Arguments:**

- `stacktraces`
- `max_report_stacktraces`

**Robot Framework Example:**

```robotframework
${stacktrace_report_data_result}=    stacktrace_report_data    ${stacktraces}    ${max_report_stacktraces}
```

---

#### stacktrace_report

**Arguments:**

- `stacktraces`

**Robot Framework Example:**

```robotframework
${stacktrace_report_result}=    stacktrace_report    ${stacktraces}
```

---

#### create_github_issue

**Arguments:**

- `repo`
- `content`
- `app_name`

**Robot Framework Example:**

```robotframework
${create_github_issue_result}=    create_github_issue    ${repo}    ${content}    example-name
```

---

### _test_parsers Library

#### test_golang_report

**Robot Framework Example:**

```robotframework
${test_golang_report_result}=    test_golang_report
```

---

### repository Library

#### Repository.list_issues

**Arguments:**

- `state`

**Robot Framework Example:**

```robotframework
${repository_list_issues_result}=    Repository.list_issues    ${state}
```

---

#### Repository.create_issue

**Arguments:**

- `title`
- `body`
- `labels`
- `assignees`

**Robot Framework Example:**

```robotframework
${repository_create_issue_result}=    Repository.create_issue    ${title}    ${body}    ${labels}    ...
```

---

#### list_issues

**Arguments:**

- `state`

**Robot Framework Example:**

```robotframework
${list_issues_result}=    list_issues    ${state}
```

---

#### create_issue

**Arguments:**

- `title`
- `body`
- `labels`
- `assignees`

**Robot Framework Example:**

```robotframework
${create_issue_result}=    create_issue    ${title}    ${body}    ${labels}    ...
```

---

### k8s_log Library

#### calculate_log_health_score

Calculate a health score based on log scan results.

Args:
    scan_results: Results from log scanning

**Arguments:**

- `scan_results`

**Returns:**

- Health score between 0.0 (unhealthy) and 1.0 (healthy)

**Robot Framework Example:**

```robotframework
${calculate_log_health_score_result}=    calculate_log_health_score    ${scan_results}
```

---

### k8s_helper Library

#### sanitize_messages

Sanitize the message string by replacing ncharacters that can't be processed into json issue details.

Args:
- input_string: The string to be sanitized.

**Arguments:**

- `input_string`

**Returns:**

- - The sanitized string.

**Robot Framework Example:**

```robotframework
${sanitize_messages_result}=    sanitize_messages    ${input_string}
```

---

## Kubernetes

### k8s_log Library

#### K8sLog.fetch_workload_logs

Fetch logs for a Kubernetes workload and prepare them for analysis.

Args:
    workload_type: Type of workload (deployment, statefulset, daemonset)
    workload_name: Name of the workload
    namespace: Kubernetes namespace
    context: Kubernetes context
    kubeconfig: Kubernetes kubeconfig secret
    log_age: How far back to fetch logs (default: 10m)

**Arguments:**

- `workload_type`
- `workload_name`
- `namespace`
- `context`
- `kubeconfig`
- `log_age`

**Returns:**

- Path to the directory containing fetched logs

**Robot Framework Example:**

```robotframework
${k8slog_fetch_workload_logs_result}=    K8sLog.fetch_workload_logs    ${workload_type}    example-name    example-name    ...
```

---

#### K8sLog.scan_logs_for_issues

Scan fetched logs for various error patterns and issues.

Args:
    log_dir: Directory containing the fetched logs
    workload_type: Type of workload
    workload_name: Name of the workload  
    namespace: Kubernetes namespace
    categories: List of categories to scan for (optional, defaults to all)

**Arguments:**

- `log_dir`
- `workload_type`
- `workload_name`
- `namespace`
- `categories`

**Returns:**

- Dictionary containing scan results with issues and summary

**Robot Framework Example:**

```robotframework
${k8slog_scan_logs_for_issues_result}=    K8sLog.scan_logs_for_issues    ${log_dir}    ${workload_type}    example-name    ...
```

---

#### K8sLog.analyze_log_anomalies

Analyze logs for repeating patterns and anomalies.

Args:
    log_dir: Directory containing the fetched logs
    workload_type: Type of workload
    workload_name: Name of the workload
    namespace: Kubernetes namespace

**Arguments:**

- `log_dir`
- `workload_type`
- `workload_name`
- `namespace`

**Returns:**

- Dictionary containing anomaly analysis results

**Robot Framework Example:**

```robotframework
${k8slog_analyze_log_anomalies_result}=    K8sLog.analyze_log_anomalies    ${log_dir}    ${workload_type}    example-name    ...
```

---

#### K8sLog.summarize_log_issues

Create a readable summary of log issues using the summarize script.

Args:
    issue_details: Raw issue details to summarize

**Arguments:**

- `issue_details`

**Returns:**

- Summarized and formatted issue details

**Robot Framework Example:**

```robotframework
${k8slog_summarize_log_issues_result}=    K8sLog.summarize_log_issues    ${issue_details}
```

---

#### K8sLog.calculate_log_health_score

Calculate a health score based on log scan results.

Args:
    scan_results: Results from log scanning

**Arguments:**

- `scan_results`

**Returns:**

- Health score between 0.0 (unhealthy) and 1.0 (healthy)

**Robot Framework Example:**

```robotframework
${k8slog_calculate_log_health_score_result}=    K8sLog.calculate_log_health_score    ${scan_results}
```

---

#### K8sLog.cleanup_temp_files

Clean up temporary files created during log analysis.

**Robot Framework Example:**

```robotframework
${k8slog_cleanup_temp_files_result}=    K8sLog.cleanup_temp_files
```

---

#### fetch_workload_logs

Fetch logs for a Kubernetes workload and prepare them for analysis.

Args:
    workload_type: Type of workload (deployment, statefulset, daemonset)
    workload_name: Name of the workload
    namespace: Kubernetes namespace
    context: Kubernetes context
    kubeconfig: Kubernetes kubeconfig secret
    log_age: How far back to fetch logs (default: 10m)

**Arguments:**

- `workload_type`
- `workload_name`
- `namespace`
- `context`
- `kubeconfig`
- `log_age`

**Returns:**

- Path to the directory containing fetched logs

**Robot Framework Example:**

```robotframework
${fetch_workload_logs_result}=    fetch_workload_logs    ${workload_type}    example-name    example-name    ...
```

---

#### scan_logs_for_issues

Scan fetched logs for various error patterns and issues.

Args:
    log_dir: Directory containing the fetched logs
    workload_type: Type of workload
    workload_name: Name of the workload  
    namespace: Kubernetes namespace
    categories: List of categories to scan for (optional, defaults to all)

**Arguments:**

- `log_dir`
- `workload_type`
- `workload_name`
- `namespace`
- `categories`

**Returns:**

- Dictionary containing scan results with issues and summary

**Robot Framework Example:**

```robotframework
${scan_logs_for_issues_result}=    scan_logs_for_issues    ${log_dir}    ${workload_type}    example-name    ...
```

---

#### analyze_log_anomalies

Analyze logs for repeating patterns and anomalies.

Args:
    log_dir: Directory containing the fetched logs
    workload_type: Type of workload
    workload_name: Name of the workload
    namespace: Kubernetes namespace

**Arguments:**

- `log_dir`
- `workload_type`
- `workload_name`
- `namespace`

**Returns:**

- Dictionary containing anomaly analysis results

**Robot Framework Example:**

```robotframework
${analyze_log_anomalies_result}=    analyze_log_anomalies    ${log_dir}    ${workload_type}    example-name    ...
```

---

### cli_utils Library

#### verify_rsp

Utility method to verify the ShellServieResponse is in the desired state
and raise exceptions if not.

Args:
    rsp (platform.ShellServiceResponse): the rsp to verify
    expected_rsp_statuscodes (list[int], optional): the http response code returned by the process/shell service API, not the same as the bash return code. Defaults to [200].
    expected_rsp_returncodes (list[int], optional): the shell return code. Defaults to [0].
    contains_stderr_ok (bool, optional): if the presence of stderr is considered to be OK. This is expect for many CLI tools. Defaults to True.

Raises:
    ValueError: indicates the presence of an undesired value in the response object

**Arguments:**

- `rsp`
- `expected_rsp_statuscodes`
- `expected_rsp_returncodes`
- `contains_stderr_ok`

**Robot Framework Example:**

```robotframework
${verify_rsp_result}=    verify_rsp    ${rsp}    ${expected_rsp_statuscodes}    ${expected_rsp_returncodes}    ...
```

---

#### escape_str_for_exec

Simple helper method to escape specific characters that cause issues in the pod exec passthrough
Args:
    string (str): original string for exec passthrough

**Arguments:**

- `string`
- `escapes`

**Returns:**

- str: string with triple escaped quotes for passthrough

**Robot Framework Example:**

```robotframework
${escape_str_for_exec_result}=    escape_str_for_exec    ${string}    ${escapes}
```

---

### json_parser Library

#### parse_cli_json_output

Parser for json blob data that can raise issues to the RunWhen platform based on data found.
Queries can be performed on the data using various kwarg structures with the following syntax:

kwarg syntax:
- extract_path_to_var__{variable_name}
- from_var_with_path__{variable1}__to__{variable2}
- assign_stdout_from_var
- {variable_name}__raise_issue_if_gt|lt|contains|ncontains|eq|neq

Using the `__` delimiters to separate values and prefixes.


Args:
    rsp (platform.ShellServiceResponse): _description_
    set_severity_level (int, optional): the severity of the issue if it's raised. Defaults to 4.
    set_issue_expected (str, optional): what we expected in the json data. Defaults to "".
    set_issue_actual (str, optional): what was actually detected in the json data. Defaults to "".
    set_issue_reproduce_hint (str, optional): reproduce hints as a string. Defaults to "".
    set_issue_title (str, optional): the title of the issue if raised. Defaults to "".
    set_issue_details (str, optional): details on the issue if raised. Defaults to "".
    set_issue_next_steps (str, optional): next steps or tasks to run based on this issue if raised. Defaults to "".
    expected_rsp_statuscodes (list[int], optional): allowed http codes in the response being parsed. Defaults to [200].
    expected_rsp_returncodes (list[int], optional): allowed shell return codes in the response being parsed. Defaults to [0].
    raise_issue_from_rsp_code (bool, optional): if true, raise an issue when the response object fails validation. Defaults to False.
    contains_stderr_ok (bool, optional): whether or not to fail validation of the response object when it contains stderr. Defaults to True.

**Arguments:**

- `rsp`
- `set_severity_level`
- `set_issue_expected`
- `set_issue_actual`
- `set_issue_reproduce_hint`
- `set_issue_title`
- `set_issue_details`
- `set_issue_next_steps`
- `expected_rsp_statuscodes`
- `expected_rsp_returncodes`
- `raise_issue_from_rsp_code`
- `contains_stderr_ok`

**Returns:**

- platform.ShellServiceResponse: the unchanged response object that was parsed, for subsequent parses.

**Robot Framework Example:**

```robotframework
${parse_cli_json_output_result}=    parse_cli_json_output    ${rsp}    ${set_severity_level}    ${set_issue_expected}    ...
```

---

### postgres_helper Library

#### k8s_postgres_query

**Arguments:**

- `query`
- `context`
- `namespace`
- `kubeconfig`
- `binary_name`
- `env`
- `labels`
- `workload_name`
- `container_name`
- `database_name`
- `opt_flags`

**Robot Framework Example:**

```robotframework
${k8s_postgres_query_result}=    k8s_postgres_query    ${query}    ${context}    example-name    ...
```

---

### CLI Library

#### execute_command

If 'service' is None, run the command locally via 'execute_local_command'.
Otherwise, run it via 'platform.execute_shell_command'.

**Arguments:**

- `cmd`
- `service`
- `request_secrets`
- `env`
- `files`
- `timeout_seconds`
- `cwd`

**Robot Framework Example:**

```robotframework
${execute_command_result}=    execute_command    ${cmd}    ${service}    ${request_secrets}    ...
```

---

#### run_bash_file

Runs a bash file from the local file system or remotely on a shellservice,
automatically staging it in CODEBUNDLE_TEMP_DIR if available.

1) Find the local path to `bash_file` (or fallback via resolve_path_to_robot).
2) Copy that script and all sibling files into CODEBUNDLE_TEMP_DIR (if set),
   or else an ephemeral tmp directory.
3) Call `execute_command()` to actually run the script from that directory.
4) If 'service' is provided, run on a remote shell; if not, run locally.

Secrets and environment variables (e.g., AZURE_CONFIG_DIR) are still handled
automatically in `execute_command()`.

**Arguments:**

- `bash_file`
- `target_service`
- `env`
- `include_in_history`
- `cmd_override`
- `timeout_seconds`

**Robot Framework Example:**

```robotframework
${run_bash_file_result}=    run_bash_file    /path/to/file    ${target_service}    ${env}    ...
```

---

#### run_cli

Executes a string of shell commands either locally or remotely (if target_service is given).
- If CODEBUNDLE_TEMP_DIR is set, commands are run from that directory.
- Preserves the existing logic for:
  * loop_with_items
  * run_in_workload_with_name / run_in_workload_with_labels
  * secrets
  * environment
  * debug/logging

**Arguments:**

- `cmd`
- `target_service`
- `env`
- `loop_with_items`
- `run_in_workload_with_name`
- `run_in_workload_with_labels`
- `optional_namespace`
- `optional_context`
- `include_in_history`
- `timeout_seconds`
- `debug`

**Robot Framework Example:**

```robotframework
${run_cli_result}=    run_cli    ${cmd}    ${target_service}    ${env}    ...
```

---

### stdout_parser Library

#### parse_cli_output_by_line

A parser that executes platform API requests as it traverses the provided stdout by line.
This allows authors to 'raise an issue' for a given line in stdout, providing valuable information for troubleshooting.

For each line traversed, the parser will check the contents using a variety of functions based on the kwargs provided
with the following structure:

    <capture_group_name>__raise_issue_<query_type>=<value>

the following capture groups are always set:
- _stdout: the entire stdout contents
- _line: the current line being parsed

example: _line__raise_issue_if_contains=Error
This will raise an issue to the platform if any _line contains the string "Error"

- parsing needs to be performed on a platform.ShellServiceResponse object (contains the stdout)

To set the payload of the issue that will be submitted to the platform, you can use the various
set_issue_* arguments.

Args:
    rsp (platform.ShellServiceResponse): The structured response from a previous command
    lines_like_regexp (str, optional): the regexp to use to create capture groups. Defaults to "".
    issue_if_no_capture_groups (bool, optional): raise an issue if no contents could be parsed to groups. Defaults to False.
    set_severity_level (int, optional): The severity of the issue, with 1 being the most critical. Defaults to 4.
    set_issue_expected (str, optional): A explanation for what we expected to see for a healthy state. Defaults to "".
    set_issue_actual (str, optional): What we actually found that's unhealthy. Defaults to "".
    set_issue_reproduce_hint (str, optional): Steps to reproduce the problem if applicable. Defaults to "".
    set_issue_title (str, optional): The title of the issue. Defaults to "".
    set_issue_details (str, optional): Further details or explanations for the issue. Defaults to "".
    set_issue_next_steps (str, optional): A next_steps query for the platform to infer suggestions from. Defaults to "".
    expected_rsp_statuscodes (list[int], optional): Acceptable http codes in the response object. Defaults to [200].
    expected_rsp_returncodes (list[int], optional): Acceptable shell return codes in the response object. Defaults to [0].
    contains_stderr_ok (bool, optional): If it's acceptable for the response object to contain stderr contents. Defaults to True.
    raise_issue_if_no_groups_found (bool, optional):  Defaults to True.
    raise_issue_from_rsp_code (bool, optional): Switch to raise issue or actual exception depending on response object codes. Defaults to False.


    overrided by using the kwarg: assign_stdout_from_var=<group>

**Arguments:**

- `rsp`
- `lines_like_regexp`
- `issue_if_no_capture_groups`
- `set_severity_level`
- `set_issue_expected`
- `set_issue_actual`
- `set_issue_reproduce_hint`
- `set_issue_title`
- `set_issue_details`
- `set_issue_next_steps`
- `expected_rsp_statuscodes`
- `expected_rsp_returncodes`
- `contains_stderr_ok`
- `raise_issue_if_no_groups_found`
- `raise_issue_from_rsp_code`

**Returns:**

- platform.ShellServiceResponse: The response object used. Typically unchanged but the stdout can be

**Robot Framework Example:**

```robotframework
${parse_cli_output_by_line_result}=    parse_cli_output_by_line    ${rsp}    ${lines_like_regexp}    ${issue_if_no_capture_groups}    ...
```

---

### k8s_helper Library

#### get_related_resource_recommendations

Parse a Kubernetes object JSON for specific annotations or labels and return recommendations.

Args:
obj_json (dict): The Kubernetes object JSON.

**Arguments:**

- `k8s_object`

**Returns:**

- str: Recommendations based on the object's annotations or labels.

**Robot Framework Example:**

```robotframework
${get_related_resource_recommendations_result}=    get_related_resource_recommendations    ${k8s_object}
```

---

## File Operations

### k8s_applications Library

#### get_file_contents_peek

**Arguments:**

- `filename`
- `st`

**Robot Framework Example:**

```robotframework
${get_file_contents_peek_result}=    get_file_contents_peek    /path/to/file    ${st}
```

---

### repository Library

#### GitCommit.changed_files

**Robot Framework Example:**

```robotframework
${gitcommit_changed_files_result}=    GitCommit.changed_files
```

---

#### RepositoryFile.search

**Arguments:**

- `search_term`

**Robot Framework Example:**

```robotframework
${repositoryfile_search_result}=    RepositoryFile.search    ${search_term}
```

---

#### RepositoryFile.content_peek

**Arguments:**

- `line_num`
- `before`
- `after`

**Robot Framework Example:**

```robotframework
${repositoryfile_content_peek_result}=    RepositoryFile.content_peek    ${line_num}    ${before}    ${after}
```

---

#### RepositoryFile.git_add

**Robot Framework Example:**

```robotframework
${repositoryfile_git_add_result}=    RepositoryFile.git_add
```

---

#### RepositoryFile.write_content

**Robot Framework Example:**

```robotframework
${repositoryfile_write_content_result}=    RepositoryFile.write_content
```

---

#### RepositoryFiles.add_source_file

**Arguments:**

- `src_file`

**Robot Framework Example:**

```robotframework
${repositoryfiles_add_source_file_result}=    RepositoryFiles.add_source_file    /path/to/file
```

---

#### RepositoryFiles.file_paths

**Robot Framework Example:**

```robotframework
${repositoryfiles_file_paths_result}=    RepositoryFiles.file_paths
```

---

#### RepositoryFiles.all_files

**Robot Framework Example:**

```robotframework
${repositoryfiles_all_files_result}=    RepositoryFiles.all_files
```

---

#### RepositoryFiles.all_basenames

**Robot Framework Example:**

```robotframework
${repositoryfiles_all_basenames_result}=    RepositoryFiles.all_basenames
```

---

#### Repository.find_file

**Arguments:**

- `filename`

**Robot Framework Example:**

```robotframework
${repository_find_file_result}=    Repository.find_file    /path/to/file
```

---

#### Repository.is_text_file

**Arguments:**

- `file_path`

**Robot Framework Example:**

```robotframework
${repository_is_text_file_result}=    Repository.is_text_file    /path/to/file
```

---

#### Repository.create_file_list

**Robot Framework Example:**

```robotframework
${repository_create_file_list_result}=    Repository.create_file_list
```

---

#### Repository.get_commits_that_changed_file

**Arguments:**

- `filename`

**Robot Framework Example:**

```robotframework
${repository_get_commits_that_changed_file_result}=    Repository.get_commits_that_changed_file    /path/to/file
```

---

#### changed_files

**Robot Framework Example:**

```robotframework
${changed_files_result}=    changed_files
```

---

#### write_content

**Robot Framework Example:**

```robotframework
${write_content_result}=    write_content
```

---

#### add_source_file

**Arguments:**

- `src_file`

**Robot Framework Example:**

```robotframework
${add_source_file_result}=    add_source_file    /path/to/file
```

---

#### file_paths

**Robot Framework Example:**

```robotframework
${file_paths_result}=    file_paths
```

---

#### all_files

**Robot Framework Example:**

```robotframework
${all_files_result}=    all_files
```

---

#### find_file

**Arguments:**

- `filename`

**Robot Framework Example:**

```robotframework
${find_file_result}=    find_file    /path/to/file
```

---

#### is_text_file

**Arguments:**

- `file_path`

**Robot Framework Example:**

```robotframework
${is_text_file_result}=    is_text_file    /path/to/file
```

---

#### create_file_list

**Robot Framework Example:**

```robotframework
${create_file_list_result}=    create_file_list
```

---

#### get_commits_that_changed_file

**Arguments:**

- `filename`

**Robot Framework Example:**

```robotframework
${get_commits_that_changed_file_result}=    get_commits_that_changed_file    /path/to/file
```

---

### parsers Library

#### StackTraceData.first_file

**Robot Framework Example:**

```robotframework
${stacktracedata_first_file_result}=    StackTraceData.first_file
```

---

#### StackTraceData.get_first_file_line_nums_as_str

**Robot Framework Example:**

```robotframework
${stacktracedata_get_first_file_line_nums_as_str_result}=    StackTraceData.get_first_file_line_nums_as_str
```

---

#### BaseStackTraceParse.extract_files

**Arguments:**

- `text`
- `show_debug`
- `exclude_paths`

**Robot Framework Example:**

```robotframework
${basestacktraceparse_extract_files_result}=    BaseStackTraceParse.extract_files    ${text}    ${show_debug}    /path/to/file
```

---

#### PythonStackTraceParse.extract_files

**Arguments:**

- `text`
- `show_debug`
- `exclude_paths`

**Robot Framework Example:**

```robotframework
${pythonstacktraceparse_extract_files_result}=    PythonStackTraceParse.extract_files    ${text}    ${show_debug}    /path/to/file
```

---

#### GoLangStackTraceParse.extract_files

**Arguments:**

- `text`
- `show_debug`
- `exclude_paths`

**Robot Framework Example:**

```robotframework
${golangstacktraceparse_extract_files_result}=    GoLangStackTraceParse.extract_files    ${text}    ${show_debug}    /path/to/file
```

---

#### first_file

**Robot Framework Example:**

```robotframework
${first_file_result}=    first_file
```

---

#### get_first_file_line_nums_as_str

**Robot Framework Example:**

```robotframework
${get_first_file_line_nums_as_str_result}=    get_first_file_line_nums_as_str
```

---

#### extract_files

**Arguments:**

- `text`
- `show_debug`
- `exclude_paths`

**Robot Framework Example:**

```robotframework
${extract_files_result}=    extract_files    ${text}    ${show_debug}    /path/to/file
```

---

#### extract_files

**Arguments:**

- `text`
- `show_debug`
- `exclude_paths`

**Robot Framework Example:**

```robotframework
${extract_files_result}=    extract_files    ${text}    ${show_debug}    /path/to/file
```

---

#### extract_files

**Arguments:**

- `text`
- `show_debug`
- `exclude_paths`

**Robot Framework Example:**

```robotframework
${extract_files_result}=    extract_files    ${text}    ${show_debug}    /path/to/file
```

---

### k8s_log Library

#### summarize_log_issues

Create a readable summary of log issues using the summarize script.

Args:
    issue_details: Raw issue details to summarize

**Arguments:**

- `issue_details`

**Returns:**

- Summarized and formatted issue details

**Robot Framework Example:**

```robotframework
${summarize_log_issues_result}=    summarize_log_issues    ${issue_details}
```

---

#### cleanup_temp_files

Clean up temporary files created during log analysis.

**Robot Framework Example:**

```robotframework
${cleanup_temp_files_result}=    cleanup_temp_files
```

---

### CLI Library

#### find_file

Helper function to check if a file exists in the given paths.

**Robot Framework Example:**

```robotframework
${find_file_result}=    find_file
```

---

#### resolve_path_to_robot

**Robot Framework Example:**

```robotframework
${resolve_path_to_robot_result}=    resolve_path_to_robot
```

---

#### string_to_datetime

Helper to convert readable duration strings (eg: 1d2m36s) to a datetime.

**Arguments:**

- `duration_str`

**Robot Framework Example:**

```robotframework
${string_to_datetime_result}=    string_to_datetime    ${duration_str}
```

---

## HTTP/API

### parsers Library

#### BaseStackTraceParse.extract_endpoints

**Arguments:**

- `text`
- `show_debug`
- `exclude_paths`

**Robot Framework Example:**

```robotframework
${basestacktraceparse_extract_endpoints_result}=    BaseStackTraceParse.extract_endpoints    ${text}    ${show_debug}    /path/to/file
```

---

#### GoLangStackTraceParse.extract_endpoints

**Arguments:**

- `text`
- `show_debug`
- `exclude_paths`

**Robot Framework Example:**

```robotframework
${golangstacktraceparse_extract_endpoints_result}=    GoLangStackTraceParse.extract_endpoints    ${text}    ${show_debug}    /path/to/file
```

---

#### extract_endpoints

**Arguments:**

- `text`
- `show_debug`
- `exclude_paths`

**Robot Framework Example:**

```robotframework
${extract_endpoints_result}=    extract_endpoints    ${text}    ${show_debug}    /path/to/file
```

---

#### extract_endpoints

**Arguments:**

- `text`
- `show_debug`
- `exclude_paths`

**Robot Framework Example:**

```robotframework
${extract_endpoints_result}=    extract_endpoints    ${text}    ${show_debug}    /path/to/file
```

---

### local_process Library

#### execute_local_command

Runs a local bash command via subprocess, with optional secrets, environment, and file copying.
Instead of ephemeral mkdtemp usage, we store everything in CODEBUNDLE_TEMP_DIR if set,
otherwise in the current directory, so the files persist after execution.

Args:
    cmd (str): The command to run (e.g., "ls -l").
    request_secrets (list): Secrets to inject either as environment variables or as files.
    env (dict): Additional environment variables for this process.
    files (dict): A dict of filename -> contents to be written in the working directory.
    timeout_seconds (int): Subprocess timeout.

**Arguments:**

- `cmd`
- `request_secrets`
- `env`
- `files`
- `timeout_seconds`
- `cwd`

**Returns:**

- platform.ShellServiceResponse

**Robot Framework Example:**

```robotframework
${execute_local_command_result}=    execute_local_command    ${cmd}    ${request_secrets}    ${env}    ...
```

---

## Utilities

### jenkins Library

#### Jenkins.parse_atom_feed

Fetches and parses the Jenkins manage/log Atom feed, returning the combined log text.
Any sensitive information like initial admin passwords will be redacted.

Example usage:
| ${logs}= | Parse Jenkins Atom Feed | ${JENKINS_URL} | ${JENKINS_USERNAME} | ${JENKINS_TOKEN} |
| Log      | Jenkins logs: ${logs}   |

**Arguments:**

- `jenkins_url`
- `jenkins_username`
- `jenkins_token`

**Robot Framework Example:**

```robotframework
${jenkins_parse_atom_feed_result}=    Jenkins.parse_atom_feed    https://example.com    example-name    ${jenkins_token}
```

---

#### parse_atom_feed

Fetches and parses the Jenkins manage/log Atom feed, returning the combined log text.
Any sensitive information like initial admin passwords will be redacted.

Example usage:
| ${logs}= | Parse Jenkins Atom Feed | ${JENKINS_URL} | ${JENKINS_USERNAME} | ${JENKINS_TOKEN} |
| Log      | Jenkins logs: ${logs}   |

**Arguments:**

- `jenkins_url`
- `jenkins_username`
- `jenkins_token`

**Robot Framework Example:**

```robotframework
${parse_atom_feed_result}=    parse_atom_feed    https://example.com    example-name    ${jenkins_token}
```

---

### k8s_applications Library

#### format_process_list

**Arguments:**

- `proc_list`

**Robot Framework Example:**

```robotframework
${format_process_list_result}=    format_process_list    ${proc_list}
```

---

#### parse_django_stacktraces

**Arguments:**

- `logs`

**Robot Framework Example:**

```robotframework
${parse_django_stacktraces_result}=    parse_django_stacktraces    ${logs}
```

---

#### parse_django_json_stacktraces

**Arguments:**

- `logs`
- `show_debug`

**Robot Framework Example:**

```robotframework
${parse_django_json_stacktraces_result}=    parse_django_json_stacktraces    ${logs}    ${show_debug}
```

---

#### parse_golang_json_stacktraces

**Arguments:**

- `logs`
- `show_debug`

**Robot Framework Example:**

```robotframework
${parse_golang_json_stacktraces_result}=    parse_golang_json_stacktraces    ${logs}    ${show_debug}
```

---

#### dynamic_parse_stacktraces

Allows for dynamic parsing of stacktraces based on the first log line
if no parser name is provided, the first log line will be used to determine the parser to use
based on a map lookup of parser types to their respective parsers

Args:
    logs (str): the log data to parse
    parser_name (str, optional): the name of the parser to lookup for use. Defaults to "".
    parse_mode (ParseMode, optional): how to modify the ingested logs, typically we want to split them on newlines. Defaults to ParseMode.SPLIT_INPUT.
    show_debug (bool, optional): Defaults to False.

**Arguments:**

- `logs`
- `parser_name`
- `parse_mode`
- `show_debug`

**Returns:**

- list[StackTraceData]: Returns a list of StackTraceData objects that contain the parsed stacktrace data to be leveraged by other functions

**Robot Framework Example:**

```robotframework
${dynamic_parse_stacktraces_result}=    dynamic_parse_stacktraces    ${logs}    example-name    ${parse_mode}    ...
```

---

#### determine_parser

**Arguments:**

- `first_line`

**Robot Framework Example:**

```robotframework
${determine_parser_result}=    determine_parser    ${first_line}
```

---

#### parse_stacktraces

**Arguments:**

- `logs`
- `parse_mode`
- `parser_override`
- `show_debug`

**Robot Framework Example:**

```robotframework
${parse_stacktraces_result}=    parse_stacktraces    ${logs}    ${parse_mode}    ${parser_override}    ...
```

---

### _test_parsers Library

#### test_python_parser

**Robot Framework Example:**

```robotframework
${test_python_parser_result}=    test_python_parser
```

---

#### test_google_drf_parser

**Robot Framework Example:**

```robotframework
${test_google_drf_parser_result}=    test_google_drf_parser
```

---

#### test_golang_parser

**Robot Framework Example:**

```robotframework
${test_golang_parser_result}=    test_golang_parser
```

---

#### test_golangjson_parse

**Robot Framework Example:**

```robotframework
${test_golangjson_parse_result}=    test_golangjson_parse
```

---

### parsers Library

#### BaseStackTraceParse.is_json

**Arguments:**

- `data`

**Robot Framework Example:**

```robotframework
${basestacktraceparse_is_json_result}=    BaseStackTraceParse.is_json    ${data}
```

---

#### BaseStackTraceParse.parse_log

**Arguments:**

- `log`
- `show_debug`

**Robot Framework Example:**

```robotframework
${basestacktraceparse_parse_log_result}=    BaseStackTraceParse.parse_log    ${log}    ${show_debug}
```

---

#### BaseStackTraceParse.extract_line_nums

**Arguments:**

- `text`
- `show_debug`
- `exclude_paths`

**Robot Framework Example:**

```robotframework
${basestacktraceparse_extract_line_nums_result}=    BaseStackTraceParse.extract_line_nums    ${text}    ${show_debug}    /path/to/file
```

---

#### BaseStackTraceParse.extract_urls

**Arguments:**

- `text`
- `show_debug`

**Robot Framework Example:**

```robotframework
${basestacktraceparse_extract_urls_result}=    BaseStackTraceParse.extract_urls    ${text}    ${show_debug}
```

---

#### BaseStackTraceParse.extract_sentences

**Arguments:**

- `text`
- `show_debug`

**Robot Framework Example:**

```robotframework
${basestacktraceparse_extract_sentences_result}=    BaseStackTraceParse.extract_sentences    ${text}    ${show_debug}
```

---

#### CSharpStackTraceParse.parse_log

**Arguments:**

- `log`
- `show_debug`

**Robot Framework Example:**

```robotframework
${csharpstacktraceparse_parse_log_result}=    CSharpStackTraceParse.parse_log    ${log}    ${show_debug}
```

---

#### PythonStackTraceParse.extract_sentences

**Arguments:**

- `text`
- `show_debug`

**Robot Framework Example:**

```robotframework
${pythonstacktraceparse_extract_sentences_result}=    PythonStackTraceParse.extract_sentences    ${text}    ${show_debug}
```

---

#### PythonStackTraceParse.extract_line_nums

**Arguments:**

- `text`
- `show_debug`
- `exclude_paths`

**Robot Framework Example:**

```robotframework
${pythonstacktraceparse_extract_line_nums_result}=    PythonStackTraceParse.extract_line_nums    ${text}    ${show_debug}    /path/to/file
```

---

#### PythonStackTraceParse.parse_log

**Arguments:**

- `log`
- `show_debug`

**Robot Framework Example:**

```robotframework
${pythonstacktraceparse_parse_log_result}=    PythonStackTraceParse.parse_log    ${log}    ${show_debug}
```

---

#### DRFStackTraceParse.parse_log

**Arguments:**

- `log`
- `show_debug`

**Robot Framework Example:**

```robotframework
${drfstacktraceparse_parse_log_result}=    DRFStackTraceParse.parse_log    ${log}    ${show_debug}
```

---

#### GoogleDRFStackTraceParse.parse_log

**Arguments:**

- `log`
- `show_debug`

**Robot Framework Example:**

```robotframework
${googledrfstacktraceparse_parse_log_result}=    GoogleDRFStackTraceParse.parse_log    ${log}    ${show_debug}
```

---

#### GoLangStackTraceParse.parse_log

**Arguments:**

- `log`
- `show_debug`

**Robot Framework Example:**

```robotframework
${golangstacktraceparse_parse_log_result}=    GoLangStackTraceParse.parse_log    ${log}    ${show_debug}
```

---

#### GoLangStackTraceParse.extract_sentences

**Arguments:**

- `text`
- `show_debug`

**Robot Framework Example:**

```robotframework
${golangstacktraceparse_extract_sentences_result}=    GoLangStackTraceParse.extract_sentences    ${text}    ${show_debug}
```

---

#### GoLangStackTraceParse.extract_line_nums

**Arguments:**

- `text`
- `show_debug`
- `exclude_paths`

**Robot Framework Example:**

```robotframework
${golangstacktraceparse_extract_line_nums_result}=    GoLangStackTraceParse.extract_line_nums    ${text}    ${show_debug}    /path/to/file
```

---

#### GoLangJsonStackTraceParse.parse_log

**Arguments:**

- `log`
- `show_debug`

**Robot Framework Example:**

```robotframework
${golangjsonstacktraceparse_parse_log_result}=    GoLangJsonStackTraceParse.parse_log    ${log}    ${show_debug}
```

---

#### parse_log

**Arguments:**

- `log`
- `show_debug`

**Robot Framework Example:**

```robotframework
${parse_log_result}=    parse_log    ${log}    ${show_debug}
```

---

#### parse_log

**Arguments:**

- `log`
- `show_debug`

**Robot Framework Example:**

```robotframework
${parse_log_result}=    parse_log    ${log}    ${show_debug}
```

---

#### parse_log

**Arguments:**

- `log`
- `show_debug`

**Robot Framework Example:**

```robotframework
${parse_log_result}=    parse_log    ${log}    ${show_debug}
```

---

#### parse_log

**Arguments:**

- `log`
- `show_debug`

**Robot Framework Example:**

```robotframework
${parse_log_result}=    parse_log    ${log}    ${show_debug}
```

---

#### parse_log

**Arguments:**

- `log`
- `show_debug`

**Robot Framework Example:**

```robotframework
${parse_log_result}=    parse_log    ${log}    ${show_debug}
```

---

#### parse_log

**Arguments:**

- `log`
- `show_debug`

**Robot Framework Example:**

```robotframework
${parse_log_result}=    parse_log    ${log}    ${show_debug}
```

---

#### parse_log

**Arguments:**

- `log`
- `show_debug`

**Robot Framework Example:**

```robotframework
${parse_log_result}=    parse_log    ${log}    ${show_debug}
```

---

### cli_utils Library

#### filter_by_time

Utility keyword to iterate through a list of dictionaries and remove list entries where
the specified key datetime is older than the given duration string.

Args:
    list_data (list): list of dictionaries to filter
    field_name (str): what key to use for comparisons
    operand (str, optional): Defaults to "filter_older_than".
    duration_str (str, optional): Duration string in the form of 3d2h1s. Defaults to "30m".

**Arguments:**

- `list_data`
- `field_name`
- `operand`
- `duration_str`

**Returns:**

- _type_: _description_

**Robot Framework Example:**

```robotframework
${filter_by_time_result}=    filter_by_time    ${list_data}    example-name    ${operand}    ...
```

---

### Suggest Library

#### format

**Arguments:**

- `suggestions`
- `expand_arrays`

**Robot Framework Example:**

```robotframework
${format_result}=    format    ${suggestions}    ${expand_arrays}
```

---

## Other

### jenkins Library

#### normalize_log

Normalize logs to improve pattern matching.

**Arguments:**

- `log`

**Robot Framework Example:**

```robotframework
${normalize_log_result}=    normalize_log    ${log}
```

---

#### Jenkins.get_failed_tests

Returns a list of pipelines in the 'UNSTABLE' state along with their failed tests.

**Arguments:**

- `jenkins_url`
- `jenkins_username`
- `jenkins_token`

**Robot Framework Example:**

```robotframework
${jenkins_get_failed_tests_result}=    Jenkins.get_failed_tests    https://example.com    example-name    ${jenkins_token}
```

**Additional Examples:**

```python
| ${failed_tests}=    Get Failed Tests    ${JENKINS_URL}    ${JENKINS_USERNAME}    ${JENKINS_TOKEN} |
| FOR  ${pipeline}  IN  @{failed_tests} |
|    Log  Pipeline name: ${pipeline['pipeline_details']['pipeline_name']} |
|    Log  Test results:  ${pipeline['test_results']}                     |
| END |
```

---

#### Jenkins.get_queued_builds

Get builds waiting in queue longer than the specified threshold (e.g., '10m', '1h', '1d').

Returns a list of dictionaries with details of each queued build.

Example usage in Robot:
| ${queued_builds}= | Get Queued Builds | ${JENKINS_URL} | ${JENKINS_USERNAME} | ${JENKINS_TOKEN} | 15m |
| FOR  ${build}  IN  @{queued_builds} |
|    Log  Job ${build['job_name']} has been queued for ${build['wait_time']}. |
| END |

**Arguments:**

- `jenkins_url`
- `jenkins_username`
- `jenkins_token`
- `wait_threshold`

**Robot Framework Example:**

```robotframework
${jenkins_get_queued_builds_result}=    Jenkins.get_queued_builds    https://example.com    example-name    ${jenkins_token}    ...
```

---

#### Jenkins.get_executor_utilization

Returns a list with executor utilization info for each Jenkins node.

| ${utilization}= | Get Executor Utilization | ${JENKINS_URL} | ${JENKINS_USERNAME} | ${JENKINS_TOKEN} |
| FOR  ${node}  IN  @{utilization} |
|    Log  Node ${node['node_name']} is at ${node['utilization_percentage']}% utilization. |
| END |

**Arguments:**

- `jenkins_url`
- `jenkins_username`
- `jenkins_token`

**Robot Framework Example:**

```robotframework
${jenkins_get_executor_utilization_result}=    Jenkins.get_executor_utilization    https://example.com    example-name    ${jenkins_token}
```

---

#### Jenkins.analyze_logs

Analyzes logs for common errors, prioritizing lines with ERROR, and suggests next steps.

**Arguments:**

- `logs`
- `error_patterns_file`

**Robot Framework Example:**

```robotframework
${jenkins_analyze_logs_result}=    Jenkins.analyze_logs    ${logs}    /path/to/file
```

---

#### get_failed_tests

Returns a list of pipelines in the 'UNSTABLE' state along with their failed tests.

**Arguments:**

- `jenkins_url`
- `jenkins_username`
- `jenkins_token`

**Robot Framework Example:**

```robotframework
${get_failed_tests_result}=    get_failed_tests    https://example.com    example-name    ${jenkins_token}
```

**Additional Examples:**

```python
| ${failed_tests}=    Get Failed Tests    ${JENKINS_URL}    ${JENKINS_USERNAME}    ${JENKINS_TOKEN} |
| FOR  ${pipeline}  IN  @{failed_tests} |
|    Log  Pipeline name: ${pipeline['pipeline_details']['pipeline_name']} |
|    Log  Test results:  ${pipeline['test_results']}                     |
| END |
```

---

#### get_queued_builds

Get builds waiting in queue longer than the specified threshold (e.g., '10m', '1h', '1d').

Returns a list of dictionaries with details of each queued build.

Example usage in Robot:
| ${queued_builds}= | Get Queued Builds | ${JENKINS_URL} | ${JENKINS_USERNAME} | ${JENKINS_TOKEN} | 15m |
| FOR  ${build}  IN  @{queued_builds} |
|    Log  Job ${build['job_name']} has been queued for ${build['wait_time']}. |
| END |

**Arguments:**

- `jenkins_url`
- `jenkins_username`
- `jenkins_token`
- `wait_threshold`

**Robot Framework Example:**

```robotframework
${get_queued_builds_result}=    get_queued_builds    https://example.com    example-name    ${jenkins_token}    ...
```

---

#### get_executor_utilization

Returns a list with executor utilization info for each Jenkins node.

| ${utilization}= | Get Executor Utilization | ${JENKINS_URL} | ${JENKINS_USERNAME} | ${JENKINS_TOKEN} |
| FOR  ${node}  IN  @{utilization} |
|    Log  Node ${node['node_name']} is at ${node['utilization_percentage']}% utilization. |
| END |

**Arguments:**

- `jenkins_url`
- `jenkins_username`
- `jenkins_token`

**Robot Framework Example:**

```robotframework
${get_executor_utilization_result}=    get_executor_utilization    https://example.com    example-name    ${jenkins_token}
```

---

#### analyze_logs

Analyzes logs for common errors, prioritizing lines with ERROR, and suggests next steps.

**Arguments:**

- `logs`
- `error_patterns_file`

**Robot Framework Example:**

```robotframework
${analyze_logs_result}=    analyze_logs    ${logs}    /path/to/file
```

---

### k8s_applications Library

#### serialize_env

**Arguments:**

- `printenv`

**Robot Framework Example:**

```robotframework
${serialize_env_result}=    serialize_env    ${printenv}
```

---

#### test_search

**Arguments:**

- `repo`
- `exceptions`

**Robot Framework Example:**

```robotframework
${test_search_result}=    test_search    ${repo}    ${exceptions}
```

---

#### get_test_data

**Robot Framework Example:**

```robotframework
${get_test_data_result}=    get_test_data
```

---

#### clone_repo

**Arguments:**

- `git_uri`
- `git_token`
- `number_of_commits_history`

**Robot Framework Example:**

```robotframework
${clone_repo_result}=    clone_repo    ${git_uri}    ${git_token}    ${number_of_commits_history}
```

---

#### troubleshoot_application

**Arguments:**

- `repos`
- `exceptions`
- `env`
- `process_list`
- `app_name`

**Robot Framework Example:**

```robotframework
${troubleshoot_application_result}=    troubleshoot_application    ${repos}    ${exceptions}    ${env}    ...
```

---

#### scale_up_hpa

**Arguments:**

- `infra_repo`
- `manifest_file_path`
- `increase_value`
- `set_value`
- `max_allowed_replicas`

**Robot Framework Example:**

```robotframework
${scale_up_hpa_result}=    scale_up_hpa    ${infra_repo}    /path/to/file    ${increase_value}    ...
```

---

### _test_parsers Library

#### test_no_results

**Robot Framework Example:**

```robotframework
${test_no_results_result}=    test_no_results
```

---

#### test_dynamic

**Robot Framework Example:**

```robotframework
${test_dynamic_result}=    test_dynamic
```

---

### repository Library

#### GitCommit.diff

**Robot Framework Example:**

```robotframework
${gitcommit_diff_result}=    GitCommit.diff
```

---

#### GitCommit.diff_additions

**Robot Framework Example:**

```robotframework
${gitcommit_diff_additions_result}=    GitCommit.diff_additions
```

---

#### GitCommit.diff_deletions

**Robot Framework Example:**

```robotframework
${gitcommit_diff_deletions_result}=    GitCommit.diff_deletions
```

---

#### Repository.clone_repo

**Arguments:**

- `num_commits_history`
- `cache`

**Robot Framework Example:**

```robotframework
${repository_clone_repo_result}=    Repository.clone_repo    ${num_commits_history}    ${cache}
```

---

#### Repository.git_commit

**Arguments:**

- `branch_name`
- `comment`

**Robot Framework Example:**

```robotframework
${repository_git_commit_result}=    Repository.git_commit    example-name    ${comment}
```

---

#### Repository.git_push_branch

**Arguments:**

- `branch`
- `remote`

**Robot Framework Example:**

```robotframework
${repository_git_push_branch_result}=    Repository.git_push_branch    ${branch}    ${remote}
```

---

#### Repository.git_pr

**Arguments:**

- `title`
- `branch`
- `body`
- `check_open`

**Robot Framework Example:**

```robotframework
${repository_git_pr_result}=    Repository.git_pr    ${title}    ${branch}    ${body}    ...
```

---

#### Repository.get_repo_base_url

**Robot Framework Example:**

```robotframework
${repository_get_repo_base_url_result}=    Repository.get_repo_base_url
```

---

#### Repository.search

**Arguments:**

- `search_words`
- `search_files`

**Robot Framework Example:**

```robotframework
${repository_search_result}=    Repository.search    ${search_words}    /path/to/file
```

---

#### Repository.serialize_git_commits

**Arguments:**

- `commit_list`

**Robot Framework Example:**

```robotframework
${repository_serialize_git_commits_result}=    Repository.serialize_git_commits    ${commit_list}
```

---

#### Repository.get_git_log

**Arguments:**

- `num_commits`

**Robot Framework Example:**

```robotframework
${repository_get_git_log_result}=    Repository.get_git_log    ${num_commits}
```

---

#### diff

**Robot Framework Example:**

```robotframework
${diff_result}=    diff
```

---

#### diff_additions

**Robot Framework Example:**

```robotframework
${diff_additions_result}=    diff_additions
```

---

#### diff_deletions

**Robot Framework Example:**

```robotframework
${diff_deletions_result}=    diff_deletions
```

---

#### search

**Arguments:**

- `search_term`

**Robot Framework Example:**

```robotframework
${search_result}=    search    ${search_term}
```

---

#### content_peek

**Arguments:**

- `line_num`
- `before`
- `after`

**Robot Framework Example:**

```robotframework
${content_peek_result}=    content_peek    ${line_num}    ${before}    ${after}
```

---

#### git_add

**Robot Framework Example:**

```robotframework
${git_add_result}=    git_add
```

---

#### all_basenames

**Robot Framework Example:**

```robotframework
${all_basenames_result}=    all_basenames
```

---

#### clone_repo

**Arguments:**

- `num_commits_history`
- `cache`

**Robot Framework Example:**

```robotframework
${clone_repo_result}=    clone_repo    ${num_commits_history}    ${cache}
```

---

#### git_commit

**Arguments:**

- `branch_name`
- `comment`

**Robot Framework Example:**

```robotframework
${git_commit_result}=    git_commit    example-name    ${comment}
```

---

#### git_push_branch

**Arguments:**

- `branch`
- `remote`

**Robot Framework Example:**

```robotframework
${git_push_branch_result}=    git_push_branch    ${branch}    ${remote}
```

---

#### git_pr

**Arguments:**

- `title`
- `branch`
- `body`
- `check_open`

**Robot Framework Example:**

```robotframework
${git_pr_result}=    git_pr    ${title}    ${branch}    ${body}    ...
```

---

#### get_repo_base_url

**Robot Framework Example:**

```robotframework
${get_repo_base_url_result}=    get_repo_base_url
```

---

#### search

**Arguments:**

- `search_words`
- `search_files`

**Robot Framework Example:**

```robotframework
${search_result}=    search    ${search_words}    /path/to/file
```

---

#### serialize_git_commits

**Arguments:**

- `commit_list`

**Robot Framework Example:**

```robotframework
${serialize_git_commits_result}=    serialize_git_commits    ${commit_list}
```

---

#### get_git_log

**Arguments:**

- `num_commits`

**Robot Framework Example:**

```robotframework
${get_git_log_result}=    get_git_log    ${num_commits}
```

---

### parsers Library

#### StackTraceData.has_results

**Robot Framework Example:**

```robotframework
${stacktracedata_has_results_result}=    StackTraceData.has_results
```

---

#### StackTraceData.errors_summary

**Robot Framework Example:**

```robotframework
${stacktracedata_errors_summary_result}=    StackTraceData.errors_summary
```

---

#### StackTraceData.first_line_nums

**Robot Framework Example:**

```robotframework
${stacktracedata_first_line_nums_result}=    StackTraceData.first_line_nums
```

---

#### has_results

**Robot Framework Example:**

```robotframework
${has_results_result}=    has_results
```

---

#### errors_summary

**Robot Framework Example:**

```robotframework
${errors_summary_result}=    errors_summary
```

---

#### first_line_nums

**Robot Framework Example:**

```robotframework
${first_line_nums_result}=    first_line_nums
```

---

#### is_json

**Arguments:**

- `data`

**Robot Framework Example:**

```robotframework
${is_json_result}=    is_json    ${data}
```

---

#### extract_line_nums

**Arguments:**

- `text`
- `show_debug`
- `exclude_paths`

**Robot Framework Example:**

```robotframework
${extract_line_nums_result}=    extract_line_nums    ${text}    ${show_debug}    /path/to/file
```

---

#### extract_urls

**Arguments:**

- `text`
- `show_debug`

**Robot Framework Example:**

```robotframework
${extract_urls_result}=    extract_urls    ${text}    ${show_debug}
```

---

#### extract_sentences

**Arguments:**

- `text`
- `show_debug`

**Robot Framework Example:**

```robotframework
${extract_sentences_result}=    extract_sentences    ${text}    ${show_debug}
```

---

#### extract_sentences

**Arguments:**

- `text`
- `show_debug`

**Robot Framework Example:**

```robotframework
${extract_sentences_result}=    extract_sentences    ${text}    ${show_debug}
```

---

#### extract_line_nums

**Arguments:**

- `text`
- `show_debug`
- `exclude_paths`

**Robot Framework Example:**

```robotframework
${extract_line_nums_result}=    extract_line_nums    ${text}    ${show_debug}    /path/to/file
```

---

#### extract_sentences

**Arguments:**

- `text`
- `show_debug`

**Robot Framework Example:**

```robotframework
${extract_sentences_result}=    extract_sentences    ${text}    ${show_debug}
```

---

#### extract_line_nums

**Arguments:**

- `text`
- `show_debug`
- `exclude_paths`

**Robot Framework Example:**

```robotframework
${extract_line_nums_result}=    extract_line_nums    ${text}    ${show_debug}    /path/to/file
```

---

### cli_utils Library

#### from_json

Wrapper keyword for json loads

Args:
    json_str (str): json string blob

**Arguments:**

- `json_str`

**Returns:**

- any: the loaded json object

**Robot Framework Example:**

```robotframework
${from_json_result}=    from_json    ${json_str}
```

---

#### to_json

Wrapper keyword for json dumps

Args:
    json_data (any): json data

**Arguments:**

- `json_data`

**Returns:**

- str: the str representation of the json blob

**Robot Framework Example:**

```robotframework
${to_json_result}=    to_json    ${json_data}
```

---

### postgres_helper Library

#### get_password

**Arguments:**

- `context`
- `namespace`
- `kubeconfig`
- `env`
- `labels`
- `workload_name`
- `container_name`

**Robot Framework Example:**

```robotframework
${get_password_result}=    get_password    ${context}    example-name    ${kubeconfig}    ...
```

---

#### get_user

**Arguments:**

- `context`
- `namespace`
- `kubeconfig`
- `env`
- `labels`
- `workload_name`
- `container_name`

**Robot Framework Example:**

```robotframework
${get_user_result}=    get_user    ${context}    example-name    ${kubeconfig}    ...
```

---

#### get_database

**Arguments:**

- `context`
- `namespace`
- `kubeconfig`
- `env`
- `labels`
- `workload_name`
- `container_name`

**Robot Framework Example:**

```robotframework
${get_database_result}=    get_database    ${context}    example-name    ${kubeconfig}    ...
```

---

### CLI Library

#### escape_string

**Arguments:**

- `string`

**Robot Framework Example:**

```robotframework
${escape_string_result}=    escape_string    ${string}
```

---

#### escape_bash_command

Escapes a command for safe execution in bash.

**Arguments:**

- `command`

**Robot Framework Example:**

```robotframework
${escape_bash_command_result}=    escape_bash_command    ${command}
```

---

#### pop_shell_history

Deletes the shell history up to this point and returns it as a string for display.

**Returns:**

- str: the string of shell command history

**Robot Framework Example:**

```robotframework
${pop_shell_history_result}=    pop_shell_history
```

---

### Suggest Library

#### suggest

**Arguments:**

- `search`
- `platform`
- `pretty_answer`
- `include_object_hints`
- `k_nearest`
- `minimum_match_score`

**Robot Framework Example:**

```robotframework
${suggest_result}=    suggest    ${search}    ${platform}    ${pretty_answer}    ...
```

---

## Quick Reference

### All Keywords by Library

**jenkins:**
- `normalize_log`
- `Jenkins.get_failed_tests`
- `Jenkins.get_queued_builds`
- `Jenkins.get_executor_utilization`
- `Jenkins.build_logs_analytics`
- `Jenkins.parse_atom_feed`
- `Jenkins.analyze_logs`
- `get_failed_tests`
- `get_queued_builds`
- `get_executor_utilization`
- `build_logs_analytics`
- `parse_atom_feed`
- `analyze_logs`

**k8s_applications:**
- `format_process_list`
- `serialize_env`
- `test_search`
- `get_test_data`
- `stacktrace_report_data`
- `stacktrace_report`
- `parse_django_stacktraces`
- `parse_django_json_stacktraces`
- `parse_golang_json_stacktraces`
- `dynamic_parse_stacktraces`
- `determine_parser`
- `parse_stacktraces`
- `clone_repo`
- `troubleshoot_application`
- `get_file_contents_peek`
- `create_github_issue`
- `scale_up_hpa`

**_test_parsers:**
- `test_python_parser`
- `test_google_drf_parser`
- `test_golang_parser`
- `test_golang_report`
- `test_golangjson_parse`
- `test_no_results`
- `test_dynamic`

**repository:**
- `GitCommit.changed_files`
- `GitCommit.diff`
- `GitCommit.diff_additions`
- `GitCommit.diff_deletions`
- `RepositoryFile.search`
- `RepositoryFile.content_peek`
- `RepositoryFile.git_add`
- `RepositoryFile.write_content`
- `RepositoryFiles.add_source_file`
- `RepositoryFiles.file_paths`
- `RepositoryFiles.all_files`
- `RepositoryFiles.all_basenames`
- `Repository.find_file`
- `Repository.clone_repo`
- `Repository.git_commit`
- `Repository.git_push_branch`
- `Repository.git_pr`
- `Repository.get_repo_base_url`
- `Repository.is_text_file`
- `Repository.create_file_list`
- `Repository.search`
- `Repository.get_commits_that_changed_file`
- `Repository.serialize_git_commits`
- `Repository.get_git_log`
- `Repository.list_issues`
- `Repository.create_issue`
- `changed_files`
- `diff`
- `diff_additions`
- `diff_deletions`
- `search`
- `content_peek`
- `git_add`
- `write_content`
- `add_source_file`
- `file_paths`
- `all_files`
- `all_basenames`
- `find_file`
- `clone_repo`
- `git_commit`
- `git_push_branch`
- `git_pr`
- `get_repo_base_url`
- `is_text_file`
- `create_file_list`
- `search`
- `get_commits_that_changed_file`
- `serialize_git_commits`
- `get_git_log`
- `list_issues`
- `create_issue`

**parsers:**
- `StackTraceData.has_results`
- `StackTraceData.errors_summary`
- `StackTraceData.first_file`
- `StackTraceData.first_line_nums`
- `StackTraceData.get_first_file_line_nums_as_str`
- `BaseStackTraceParse.is_json`
- `BaseStackTraceParse.parse_log`
- `BaseStackTraceParse.extract_line_nums`
- `BaseStackTraceParse.extract_files`
- `BaseStackTraceParse.extract_urls`
- `BaseStackTraceParse.extract_endpoints`
- `BaseStackTraceParse.extract_sentences`
- `CSharpStackTraceParse.parse_log`
- `PythonStackTraceParse.extract_sentences`
- `PythonStackTraceParse.extract_line_nums`
- `PythonStackTraceParse.extract_files`
- `PythonStackTraceParse.parse_log`
- `DRFStackTraceParse.parse_log`
- `GoogleDRFStackTraceParse.parse_log`
- `GoLangStackTraceParse.parse_log`
- `GoLangStackTraceParse.extract_files`
- `GoLangStackTraceParse.extract_endpoints`
- `GoLangStackTraceParse.extract_sentences`
- `GoLangStackTraceParse.extract_line_nums`
- `GoLangJsonStackTraceParse.parse_log`
- `has_results`
- `errors_summary`
- `first_file`
- `first_line_nums`
- `get_first_file_line_nums_as_str`
- `is_json`
- `parse_log`
- `extract_line_nums`
- `extract_files`
- `extract_urls`
- `extract_endpoints`
- `extract_sentences`
- `parse_log`
- `extract_sentences`
- `extract_line_nums`
- `extract_files`
- `parse_log`
- `parse_log`
- `parse_log`
- `parse_log`
- `extract_files`
- `extract_endpoints`
- `extract_sentences`
- `extract_line_nums`
- `parse_log`

**k8s_log:**
- `K8sLog.fetch_workload_logs`
- `K8sLog.scan_logs_for_issues`
- `K8sLog.analyze_log_anomalies`
- `K8sLog.summarize_log_issues`
- `K8sLog.calculate_log_health_score`
- `K8sLog.cleanup_temp_files`
- `fetch_workload_logs`
- `scan_logs_for_issues`
- `analyze_log_anomalies`
- `summarize_log_issues`
- `calculate_log_health_score`
- `cleanup_temp_files`

**cli_utils:**
- `verify_rsp`
- `from_json`
- `to_json`
- `filter_by_time`
- `escape_str_for_exec`

**json_parser:**
- `parse_cli_json_output`

**local_process:**
- `execute_local_command`

**postgres_helper:**
- `get_password`
- `get_user`
- `get_database`
- `k8s_postgres_query`

**CLI:**
- `escape_string`
- `escape_bash_command`
- `pop_shell_history`
- `execute_command`
- `find_file`
- `resolve_path_to_robot`
- `run_bash_file`
- `run_cli`
- `string_to_datetime`

**stdout_parser:**
- `parse_cli_output_by_line`

**Suggest:**
- `format`
- `suggest`

**k8s_helper:**
- `get_related_resource_recommendations`
- `sanitize_messages`

