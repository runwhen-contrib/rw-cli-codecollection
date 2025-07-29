#!/usr/bin/env python3

import os
import json
import re
from pathlib import Path
import subprocess
import tempfile
from robot.api.deco import keyword, library
from robot.api import logger
from typing import Dict, List, Any, Optional, Tuple, Union
from collections import defaultdict
from difflib import SequenceMatcher
from RW import platform


@library(scope='GLOBAL', auto_keywords=True, doc_format='reST')
class K8sLog:
    """K8s Log Analysis Library
    
    This library provides keywords for fetching and analyzing Kubernetes workload logs
    for various error patterns, anomalies, and issues. It supports deployments, 
    statefulsets, and daemonsets.
    
    The library consolidates multiple log scanning patterns into efficient, reusable
    keywords that can be used across different codebundles.
    """

    def __init__(self):
        self.ROBOT_LIBRARY_SCOPE = 'GLOBAL'
        self.temp_dir = None
        self.error_patterns = self._load_error_patterns()
        
    def _load_error_patterns(self) -> Dict[str, Any]:
        """Load error patterns from the embedded patterns data."""
        # Embedded error patterns - a subset of the most common patterns
        return {
            "infrastructure_filters": [
                {
                    "name": "health_check_normal",
                    "pattern": r"(?i)(health|ping|probe|liveness|readiness).*(?:ok|success|healthy|ready|200)",
                    "description": "Normal health check responses",
                    "exclude": True
                }
            ],
            "patterns": {
                "GenericError": [
                    {
                        "name": "generic_error",
                        "pattern": r"(?i)\b(error|err|exception|fail|fatal|panic|crash|abort)\b",
                        "severity": 2,
                        "next_steps": ["Review the error message details", "Check application logs for root cause", "Verify application configuration"]
                    }
                ],
                "Connection": [
                    {
                        "name": "connection_refused",
                        "pattern": r"(?i)(connection\s+refused|connect.*refused|refused.*connection)",
                        "severity": 2,
                        "next_steps": ["Check if target service is running", "Verify network connectivity", "Check service endpoints"]
                    },
                    {
                        "name": "connection_timeout",
                        "pattern": r"(?i)(connection\s+timeout|timeout.*connection|connect.*timeout)",
                        "severity": 2,
                        "next_steps": ["Check network latency", "Verify service availability", "Review timeout configurations"]
                    }
                ],
                "Auth": [
                    {
                        "name": "authentication_failed",
                        "pattern": r"(?i)(auth.*fail|authentication.*fail|unauthorized|401|403|forbidden)",
                        "severity": 2,
                        "next_steps": ["Check authentication credentials", "Verify service account permissions", "Review RBAC configuration"]
                    }
                ],
                "Timeout": [
                    {
                        "name": "timeout_error",
                        "pattern": r"(?i)(timeout|timed\s+out|deadline\s+exceeded)",
                        "severity": 2,
                        "next_steps": ["Check service response times", "Review timeout configurations", "Verify resource availability"]
                    }
                ],
                "Resource": [
                    {
                        "name": "out_of_memory",
                        "pattern": r"(?i)(out\s+of\s+memory|oom|memory.*exhausted|killed.*memory)",
                        "severity": 1,
                        "next_steps": ["Check memory limits", "Review memory usage patterns", "Consider increasing memory allocation"]
                    }
                ],
                "AppFailure": [
                    {
                        "name": "application_startup_failure",
                        "pattern": r"(?i)(startup.*fail|failed.*start|application.*fail|service.*fail)",
                        "severity": 2,
                        "next_steps": ["Check application configuration", "Review startup dependencies", "Verify environment variables"]
                    }
                ],
                "StackTrace": [
                    {
                        "name": "stack_trace",
                        "pattern": r"(?i)(stack\s+trace|stacktrace|traceback|at\s+.*\.java:|at\s+.*\.py:|at\s+.*\.js:)",
                        "severity": 3,
                        "next_steps": ["Review stack trace for root cause", "Check application code", "Verify input validation"]
                    }
                ],
                "Exceptions": [
                    {
                        "name": "null_pointer_exception",
                        "pattern": r"(?i)(nullpointerexception|null\s+pointer|nullptr|segmentation\s+fault)",
                        "severity": 2,
                        "next_steps": ["Review code for null pointer handling", "Check input validation", "Verify object initialization"]
                    }
                ]
            }
        }

    def _cleanup_log_line_for_grouping(self, line: str) -> str:
        """Remove variable parts of a log line for better grouping."""
        # Remove timestamps (ISO format or custom 'dd-mm-yyyy hh:mm:ss.ms')
        line = re.sub(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z?', '', line)
        line = re.sub(r'\d{2}-\d{2}-\d{4} \d{2}:\d{2}:\d{2}\.\d{3}', '', line)
        # Remove thread names in brackets
        line = re.sub(r'\[[^\][]*\]', '', line)
        # Remove UUIDs and similar trace/transaction IDs (hex or alphanumeric)
        line = re.sub(r'[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}', '', line, flags=re.IGNORECASE)
        line = re.sub(r'\b[a-f0-9]{10,}\b', '', line, flags=re.IGNORECASE) # long hex strings (trace ids)
        line = re.sub(r'\b[a-zA-Z0-9]*unknown[a-zA-Z0-9]*\b', '', line, flags=re.IGNORECASE) # IDs like '11989unknown...'
        # Remove any remaining numbers that look like IDs or counters
        line = re.sub(r'\b\d{5,}\b', '', line)
        return line

    def _generate_issue_title(self, workload_type: str, workload_name: str, sample_lines: List[str]) -> str:
        """Generate a descriptive title based on the error content."""
        title = f"Error pattern detected in {workload_type} `{workload_name}`"
        
        if not sample_lines:
            return title
            
        first_sample = sample_lines[0]
        
        # Extract error message for more specific title
        error_match = re.search(r'"error"\s*:\s*"([^"]+)"', first_sample)
        if error_match:
            error_msg = error_match.group(1)
            
            # Extract service name if present
            service_match = re.search(r'(?:could not|failed to|unable to)\s+(?:retrieve|get|fetch|connect to|add to)\s+([a-zA-Z][a-zA-Z0-9\-]{2,15})', error_msg, re.IGNORECASE)
            if service_match:
                service_name = service_match.group(1)
                # Create service-specific title with error snippet
                error_snippet = error_msg[:40].strip()
                title = f"`{service_name}` service errors in {workload_type} `{workload_name}` - \"{error_snippet}...\""
            else:
                # Extract error type for more specific title
                if 'connection refused' in error_msg.lower():
                    error_snippet = error_msg[:40].strip()
                    title = f"Connection refused errors in {workload_type} `{workload_name}` - \"{error_snippet}...\""
                elif 'timeout' in error_msg.lower():
                    error_snippet = error_msg[:40].strip()
                    title = f"Timeout errors in {workload_type} `{workload_name}` - \"{error_snippet}...\""
                elif 'rpc error' in error_msg.lower():
                    error_snippet = error_msg[:40].strip()
                    title = f"RPC communication errors in {workload_type} `{workload_name}` - \"{error_snippet}...\""
                elif 'authentication' in error_msg.lower() or 'auth' in error_msg.lower():
                    error_snippet = error_msg[:40].strip()
                    title = f"Authentication errors in {workload_type} `{workload_name}` - \"{error_snippet}...\""
                elif 'permission' in error_msg.lower() or 'forbidden' in error_msg.lower():
                    error_snippet = error_msg[:40].strip()
                    title = f"Permission/authorization errors in {workload_type} `{workload_name}` - \"{error_snippet}...\""
                elif 'not found' in error_msg.lower() or '404' in error_msg:
                    error_snippet = error_msg[:40].strip()
                    title = f"Resource not found errors in {workload_type} `{workload_name}` - \"{error_snippet}...\""
                elif 'database' in error_msg.lower() or 'db' in error_msg.lower():
                    error_snippet = error_msg[:40].strip()
                    title = f"Database connection errors in {workload_type} `{workload_name}` - \"{error_snippet}...\""
                elif 'memory' in error_msg.lower() or 'out of memory' in error_msg.lower():
                    error_snippet = error_msg[:40].strip()
                    title = f"Memory/resource exhaustion in {workload_type} `{workload_name}` - \"{error_snippet}...\""
                else:
                    # Use first part of error message for context
                    error_preview = error_msg[:40].strip()
                    if error_preview:
                        title = f"Error pattern in {workload_type} `{workload_name}` - \"{error_preview}...\""
        else:
            # Fallback title with entity names in backticks
            title = f"Error pattern detected in `{workload_name}`"
            
        return title

    @keyword
    def fetch_workload_logs(self, workload_type: str, workload_name: str, namespace: str, 
                           context: str, kubeconfig: platform.Secret, log_age: str = "10m",
                           max_log_lines: str = "1000", max_log_bytes: str = "256000") -> str:
        """Fetch logs for a Kubernetes workload and prepare them for analysis.
        
        Args:
            workload_type: Type of workload (deployment, statefulset, daemonset)
            workload_name: Name of the workload
            namespace: Kubernetes namespace
            context: Kubernetes context
            kubeconfig: Kubernetes kubeconfig secret
            log_age: How far back to fetch logs (default: 10m)
            max_log_lines: Maximum number of log lines to fetch per container (default: 1000)
            max_log_bytes: Maximum log size in bytes to fetch per container (default: 256000)
            
        Returns:
            Path to the directory containing fetched logs
        """
        # Create temporary directory for this analysis session
        if not self.temp_dir:
            self.temp_dir = tempfile.mkdtemp(prefix="k8s_log_analysis_")
        
        # Write kubeconfig to temp file
        kubeconfig_path = os.path.join(self.temp_dir, "kubeconfig")
        with open(kubeconfig_path, 'w') as f:
            f.write(kubeconfig.value)
        
        # Set environment variables including volume controls
        env = os.environ.copy()
        env.update({
            'KUBECONFIG': kubeconfig_path,
            'WORKLOAD_TYPE': workload_type,
            'WORKLOAD_NAME': workload_name,
            'NAMESPACE': namespace,
            'CONTEXT': context,
            'LOG_AGE': log_age,
            'MAX_LOG_LINES': max_log_lines,
            'MAX_LOG_BYTES': max_log_bytes
        })
        
        # Copy necessary files to temp directory
        source_dir = Path(__file__).parent.parent.parent.parent / "codebundles" / "k8s-application-log-health"
        for file_name in ["get_pod_logs_for_workload.sh", "error_patterns.json", "ignore_patterns.json"]:
            source_file = source_dir / file_name
            if source_file.exists():
                dest_file = Path(self.temp_dir) / file_name
                dest_file.write_text(source_file.read_text())
                if file_name.endswith('.sh'):
                    os.chmod(dest_file, 0o755)
        
        # Execute log fetching script
        script_path = os.path.join(self.temp_dir, "get_pod_logs_for_workload.sh")
        cmd = [script_path, workload_type, workload_name, namespace, context]
        
        try:
            result = subprocess.run(cmd, cwd=self.temp_dir, env=env, 
                                  capture_output=True, text=True, timeout=300)
            if result.returncode != 0:
                raise RuntimeError(f"Log fetching failed: {result.stderr}")
            
            logger.info(f"Successfully fetched logs for {workload_type}/{workload_name}")
            return self.temp_dir
            
        except subprocess.TimeoutExpired:
            raise RuntimeError("Log fetching timed out after 5 minutes")
        except Exception as e:
            raise RuntimeError(f"Error fetching logs: {str(e)}")

    @keyword
    def scan_logs_for_issues(self, log_dir: str, workload_type: str, workload_name: str, 
                           namespace: str, categories: List[str] = None) -> Dict[str, Any]:
        """Scan fetched logs for various error patterns and issues.
        
        Args:
            log_dir: Directory containing the fetched logs
            workload_type: Type of workload
            workload_name: Name of the workload  
            namespace: Kubernetes namespace
            categories: List of categories to scan for (optional, defaults to all)
            
        Returns:
            Dictionary containing scan results with issues and summary
        """
        if categories is None:
            categories = [
                "GenericError", "AppFailure", "StackTrace", "Connection", 
                "Timeout", "Auth", "Exceptions", "Anomaly", "AppRestart", "Resource"
            ]
        
        log_path = Path(log_dir)
        pods_json_path = log_path / "application_logs_pods.json"
        
        # Read the pods JSON
        try:
            with open(pods_json_path, "r", encoding="utf-8") as f:
                pods_data = json.load(f)
        except Exception as e:
            logger.warn(f"Error reading pods JSON: {e}")
            return {"issues": [], "summary": ["No pods data found for analysis."]}

        # Pattern aggregators
        category_issues = defaultdict(list)
        max_severity = 5

        # Map of numeric severity to text label
        severity_label_map = {
            1: "Critical",
            2: "Major", 
            3: "Minor",
            4: "Informational",
        }

        pods = [pod["metadata"]["name"] for pod in pods_data]
        logger.info(f"Scanning logs for {workload_type}/{workload_name} in namespace {namespace}...")

        for pod in pods:
            logger.info(f"Processing Pod: {pod}")
            pod_obj = next((p for p in pods_data if p["metadata"]["name"] == pod), None)
            if not pod_obj:
                continue

            containers = [c["name"] for c in pod_obj["spec"]["containers"]]

            for container in containers:
                logger.info(f"  Processing Container: {container}")

                log_file = log_path / f"{workload_type}_{workload_name}_logs" / f"{pod}_{container}_logs.txt"
                if not log_file.is_file():
                    logger.warn(f"  Warning: No log file found at {log_file}")
                    continue

                with open(log_file, "r", encoding="utf-8") as lf:
                    log_content = lf.read()

                # Skip if log content is empty or only contains "errors": []
                if not log_content.strip() or re.match(r'^\s*"errors":\s*\[\s*\]\s*$', log_content.strip()):
                    continue

                log_lines = log_content.split('\n')
                
                # Process each category
                for category in categories:
                    if category not in self.error_patterns["patterns"]:
                        continue
                        
                    patterns = self.error_patterns["patterns"][category]
                    
                    for pattern_config in patterns:
                        pattern = pattern_config["pattern"]
                        severity = pattern_config["severity"]
                        next_steps = pattern_config["next_steps"]
                        
                        matches = []
                        for line_num, line in enumerate(log_lines, 1):
                            if re.search(pattern, line):
                                matches.append({
                                    "line_number": line_num,
                                    "line": line.strip(),
                                    "pod": pod,
                                    "container": container
                                })
                        
                        if matches:
                            max_severity = min(max_severity, severity)
                            
                            # Create issue for this pattern
                            issue = {
                                "category": category,
                                "pattern_name": pattern_config["name"],
                                "severity": severity,
                                "next_steps": next_steps,
                                "matches": matches,
                                "total_occurrences": len(matches),
                                "sample_lines": [m["line"] for m in matches[:3]]  # First 3 matches as samples
                            }
                            
                            category_issues[category].append(issue)

        # Consolidate issues by pattern and create final results
        consolidated_issues = {}
        issues_json = {"issues": [], "summary": []}
        
        for category, issues in category_issues.items():
            for issue in issues:
                # Group similar issues together
                content_key = f"{category}_{issue['pattern_name']}"
                
                if content_key not in consolidated_issues:
                    consolidated_issues[content_key] = {
                        "category": category,
                        "severity": issue["severity"],
                        "total_occurrences": 0,
                        "sample_lines": [],
                        "unique_next_steps": set(),
                        "details_parts": []
                    }
                
                consolidated_data = consolidated_issues[content_key]
                consolidated_data["total_occurrences"] += issue["total_occurrences"]
                consolidated_data["sample_lines"].extend(issue["sample_lines"])
                consolidated_data["unique_next_steps"].update(issue["next_steps"])
                
                # Add details about where the issue was found
                pod_container_info = defaultdict(int)
                for match in issue["matches"]:
                    pod_container_info[f"{match['pod']}/{match['container']}"] += 1
                
                details_part = f"**Pod/Container:** {', '.join([f'{pc} ({count}x)' for pc, count in pod_container_info.items()])}"
                consolidated_data["details_parts"].append(details_part)

        # Create final issues from consolidated data
        for content_key, issue_data in consolidated_issues.items():
            # Deduplicate and clean up the merged data
            unique_details = []
            seen_details = set()
            
            for detail in issue_data["details_parts"]:
                if detail not in seen_details:
                    unique_details.append(detail)
                    seen_details.add(detail)
            
            # Take unique sample lines (up to 3)
            unique_samples = list(dict.fromkeys(issue_data["sample_lines"]))[:3]
            
            # Deduplicate next steps
            unique_next_steps = list(dict.fromkeys(issue_data["unique_next_steps"]))
            
            severity_label = severity_label_map.get(issue_data["severity"], f"Unknown({issue_data['severity']})")
            
            # Generate title without occurrence count
            title = self._generate_issue_title(workload_type, workload_name, unique_samples)
            
            # Create properly formatted details string
            details_str = "\n\n".join(unique_details)
            if unique_samples:
                details_str += f"\n\n**Sample Log Lines:**\n" + "\n".join([f"• {sample}" for sample in unique_samples])

            # Add the consolidated issues entry
            issues_json["issues"].append({
                "title": title,
                "details": details_str,
                "next_steps": "\n".join(unique_next_steps),
                "severity": issue_data["severity"], 
                "severity_label": severity_label,
                "occurrences": issue_data["total_occurrences"],
                "category": issue_data["category"]
            })

        # Generate summary
        total_issues = len(consolidated_issues)
        categories_found = set(issue_data["category"] for issue_data in consolidated_issues.values())
        
        severity_label = severity_label_map.get(max_severity, f"Unknown({max_severity})")
        issues_json["summary"].append(
            f"Found {total_issues} issue patterns in {workload_type} '{workload_name}' (ns: {namespace}). "
            f"Max severity: {severity_label}. Categories: {', '.join(sorted(categories_found))}."
        )

        if not consolidated_issues:
            issues_json["summary"].append(
                f"No issues found in {workload_type} '{workload_name}' (namespace '{namespace}')."
            )

        logger.info(f"Completed log scanning for {workload_type}/{workload_name}. Found {len(issues_json.get('issues', []))} issues.")
        return issues_json

    @keyword
    def analyze_log_anomalies(self, log_dir: str, workload_type: str, workload_name: str, 
                             namespace: str) -> Dict[str, Any]:
        """Analyze logs for repeating patterns and anomalies.
        
        Args:
            log_dir: Directory containing the fetched logs
            workload_type: Type of workload
            workload_name: Name of the workload
            namespace: Kubernetes namespace
            
        Returns:
            Dictionary containing anomaly analysis results
        """
        log_path = Path(log_dir)
        pods_json_path = log_path / "application_logs_pods.json"
        
        # Read the pods JSON
        try:
            with open(pods_json_path, "r", encoding="utf-8") as f:
                pods_data = json.load(f)
        except Exception as e:
            logger.warn(f"Error reading pods JSON: {e}")
            return {"issues": [], "summary": ["No pods data found for anomaly analysis."]}

        issues_json = {"issues": [], "summary": []}
        pods = [pod["metadata"]["name"] for pod in pods_data]
        
        logger.info(f"Scanning logs for frequent log anomalies in {workload_type}/{workload_name} in namespace {namespace}...")

        for pod in pods:
            logger.info(f"Processing Pod: {pod}")
            pod_obj = next((p for p in pods_data if p["metadata"]["name"] == pod), None)
            if not pod_obj:
                continue

            containers = [c["name"] for c in pod_obj["spec"]["containers"]]

            for container in containers:
                logger.info(f"  Processing Container: {container}")

                log_file = log_path / f"{workload_type}_{workload_name}_logs" / f"{pod}_{container}_logs.txt"
                if not log_file.is_file():
                    logger.warn(f"  Warning: No log file found at {log_file}")
                    continue

                with open(log_file, "r", encoding="utf-8") as lf:
                    log_content = lf.read()

                if not log_content.strip():
                    continue

                # Count occurrences of repeating log messages
                log_lines = log_content.split('\n')
                line_counts = defaultdict(int)
                
                for line in log_lines:
                    if line.strip():
                        # Clean the line for better grouping
                        cleaned_line = self._cleanup_log_line_for_grouping(line.strip())
                        if cleaned_line:
                            line_counts[cleaned_line] += 1

                # Find lines that appear more than once
                for cleaned_line, count in line_counts.items():
                    if count > 1:
                        severity = 3  # Default to informational
                        next_step = f"Review logs in {workload_type} `{workload_name}` to determine if frequent messages indicate an issue."

                        if count >= 10:
                            severity = 1
                            next_step = f"Critical: High volume of repeated log messages detected. Immediate investigation recommended."
                        elif count >= 5:
                            severity = 2
                            next_step = f"Warning: Repeated log messages detected. Investigate potential issues."

                        # Create issue for this anomaly
                        issues_json["issues"].append({
                            "title": f"Frequent Log Anomaly Detected in {pod} ({container})",
                            "details": f"**Repeated Message:** {cleaned_line}\n**Occurrences:** {count}\n**Pod:** {pod}\n**Container:** {container}",
                            "next_steps": next_step,
                            "severity": severity,
                            "occurrences": count
                        })

        # Generate summary
        total_anomalies = len(issues_json["issues"])
        if total_anomalies > 0:
            issues_json["summary"].append(f"Detected {total_anomalies} log anomalies across pods in {workload_type} {workload_name}.")
        else:
            issues_json["summary"].append(f"No anomalies detected in {workload_type} '{workload_name}' (namespace '{namespace}').")

        logger.info(f"Completed anomaly analysis for {workload_type}/{workload_name}. Found {len(issues_json.get('issues', []))} anomalies.")
        return issues_json

    @keyword
    def summarize_log_issues(self, issue_details: str) -> str:
        """Create a readable summary of log issues.
        
        Args:
            issue_details: Raw issue details to summarize
            
        Returns:
            Summarized and formatted issue details
        """
        # Simple built-in summarization logic
        if not issue_details or not issue_details.strip():
            return "No issue details provided."
        
        # Basic formatting and cleanup
        details = str(issue_details).strip()
        
        # Split into lines and clean up
        lines = details.split('\n')
        cleaned_lines = []
        
        for line in lines:
            line = line.strip()
            if line:
                # Remove excessive whitespace
                line = re.sub(r'\s+', ' ', line)
                cleaned_lines.append(line)
        
        # Join back together with proper formatting
        formatted_details = '\n'.join(cleaned_lines)
        
        # Add basic structure if it looks like raw log data
        if not any(marker in formatted_details.lower() for marker in ['**', 'pod:', 'container:', 'error:']):
            # Try to structure the output better
            structured_lines = []
            for line in cleaned_lines[:10]:  # Limit to first 10 lines
                if line:
                    structured_lines.append(f"• {line}")
            
            if len(cleaned_lines) > 10:
                structured_lines.append(f"... and {len(cleaned_lines) - 10} more lines")
            
            formatted_details = '\n'.join(structured_lines)
        
        return formatted_details
    
    @keyword
    def format_scan_results_for_display(self, scan_results: Union[str, Dict[str, Any]]) -> str:
        """Formats log scan results into a human-readable string for display in reports."""
        if isinstance(scan_results, str):
            try:
                scan_results = json.loads(scan_results)
            except json.JSONDecodeError:
                return "Error: Could not decode scan results."

        issues = scan_results.get("issues", [])
        if not issues:
            return "✅ No significant issues found in logs."

        report_parts = ["📋 **Log Issues Found:**", "========================================"]
        
        for issue in issues:
            title = self._safe_get(issue, 'title', 'Unknown Issue')
            severity = self._safe_get(issue, 'severity_label', 'Unknown')
            category = self._safe_get(issue, 'category', 'N/A')
            occurrences = self._safe_get(issue, 'occurrences', 'N/A')
            # The 'details' field is now pre-formatted by scan_logs.py with grouped samples and context
            details = self._safe_get(issue, 'details', '')
            key_actions = self._extract_key_actions(self._safe_get(issue, 'next_steps', ''))

            report_parts.append(f"**Issue: {title}**")
            report_parts.append(f"  • Severity: {severity} | Category: {category} | Occurrences: {occurrences}")
            if key_actions:
                report_parts.append(f"  • Key Actions: {key_actions}")
        
            # Add a separator before the detailed log groups
            report_parts.append("---")
            report_parts.append(details) # Use the pre-formatted details directly
            report_parts.append("----------------------------------------")

        return "\n".join(report_parts)
    
    def _safe_get(self, obj: Any, key: str, default: Any = None) -> Any:
        """Safely get a value from an object, handling various data types."""
        if isinstance(obj, dict):
            return obj.get(key, default)
        elif hasattr(obj, key):
            return getattr(obj, key, default)
        else:
            return default
    
    def _extract_sample_line(self, details: str) -> str:
        """Extract a meaningful sample line from issue details."""
        if not details:
            return None
            
        lines = details.split('\n')
        
        # Look for lines that contain actual log content
        for line in lines:
            line = line.strip()
            # Skip metadata lines
            if (line and 
                not line.startswith('Pod:') and 
                not line.startswith('**') and
                not line.startswith('Container:') and
                not line.startswith('Context') and
                len(line) > 10):
                
                # Look for structured log data or error messages
                if ('"error"' in line or 
                    'rpc error' in line or 
                    'failed to' in line or
                    'could not' in line or
                    'exception' in line.lower() or
                    'Request failed' in line or
                    'RethrownError' in line):
                    
                    # Return the complete line without any truncation
                    return line
        
        # Fallback: get first non-empty line without truncation
        for line in lines:
            line = line.strip()
            if line and not line.startswith('Pod:') and not line.startswith('**') and not line.startswith('Context'):
                return line
        
        return None
    
    def _extract_context_sample(self, details: str) -> list:
        """Extract context lines from issue details."""
        if not details:
            return []
            
        lines = details.split('\n')
        context_lines = []
        in_context = False
        
        for line in lines:
            line = line.strip()
            if line.startswith("Context (5 lines before/after):") or line.startswith("Context (deduplicated):"):
                in_context = True
                continue
            elif in_context and line == "":
                in_context = False
                break
            elif in_context:
                context_lines.append(line)
        
        return context_lines

    def _extract_key_actions(self, next_steps: str) -> str:
        """Extract key actions from next steps for display."""
        if not next_steps:
            return ""
        
        # Split by newlines and take the first few meaningful steps
        steps = next_steps.split('\n')
        key_steps = []
        
        for step in steps:
            step = step.strip()
            if step and len(step) > 10:  # Only include substantial steps
                key_steps.append(step)
                if len(key_steps) >= 3:  # Limit to 3 key actions
                    break
        
        return " | ".join(key_steps) if key_steps else ""
    
    def _extract_service_steps(self, next_steps: str) -> str:
        """Extract the most important service-specific action from next steps."""
        if not next_steps:
            return None
            
        lines = next_steps.split('\n')
        
        # Prioritize service-specific guidance and wrap entities in backticks
        priority_patterns = [
            r'Check.*?(?:health.*?of|availability.*?of).*?services?:\s*([^.]+)',
            r'Investigate\s+([`]?[a-zA-Z][a-zA-Z0-9\-]*[`]?)\s+service',
            r'Verify.*?connectivity.*?to\s+services?:\s*([^.]+)',
            r'Review.*?service discovery.*?for:\s*([^.]+)',
        ]
        
        for line in lines:
            for pattern in priority_patterns:
                match = re.search(pattern, line, re.IGNORECASE)
                if match:
                    service_info = match.group(1).strip()
                    # Clean up service info to remove action phrases and non-services
                    service_info = self._clean_service_info(service_info)
                    if service_info:  # Only proceed if we have clean service info
                        # Ensure proper backtick wrapping
                        if not service_info.startswith('`'):
                            service_info = self._wrap_entities_in_backticks(service_info)
                        return f"Check {service_info} service status"
        
        # Fallback: return first meaningful action with entity formatting
        for line in lines:
            line = line.strip()
            if line and len(line) > 10 and not line.startswith('Review logs'):
                # Apply entity formatting to the fallback line
                formatted_line = self._wrap_entities_in_backticks(line)
                return formatted_line[:150] + "..." if len(formatted_line) > 150 else formatted_line
        
        return None
    
    def _clean_service_info(self, service_info: str) -> str:
        """Clean service info to remove action phrases and non-service entities."""
        if not service_info:
            return ""
            
        # Split by common separators and filter out action phrases and non-services
        parts = [part.strip().strip('`').strip() for part in re.split(r'[,;]', service_info)]
        clean_parts = []
        
        # Extended list of things to filter out
        noise_patterns = [
            'add to', 'connect to', 'retrieve', 'get', 'fetch', 'connect', 'add',
            'user.*during', 'during.*checkout', 'checkout', 'user.*cart.*during',
            'error', 'desc', 'code', 'rpc', 'tcp', 'transport', 'dialing'
        ]
        
        for part in parts:
            part = part.strip()
            if (part and 
                len(part) > 1 and
                len(part) < 30 and  # Service names shouldn't be too long
                not part.lower().startswith('user ') and  # Filter user-related phrases
                not any(re.search(pattern, part, re.IGNORECASE) for pattern in noise_patterns) and
                # Service names typically contain 'service' or are short descriptive names
                (('service' in part.lower() and len(part) < 20) or 
                 (len(part) <= 15 and re.match(r'^[a-zA-Z][a-zA-Z0-9\-]*$', part)))):
                clean_parts.append(part)
        
        if clean_parts:
            return ', '.join(clean_parts[:3])  # Limit to 3 services max
        return ""
    
    def _wrap_entities_in_backticks(self, text: str) -> str:
        """Wrap suspected entity names in backticks if not already wrapped."""
        if not text:
            return text
            
        # Don't double-wrap already wrapped entities
        if '`' in text:
            return text
            
        # Patterns for entity names to wrap
        entity_patterns = [
            (r'\b([a-zA-Z][a-zA-Z0-9\-]*service)\b', r'`\1`'),  # service names
            (r'\b(port[s]?)\s+([0-9]{4,5})\b', r'\1 `\2`'),   # port numbers
            (r'\b([a-zA-Z][a-zA-Z0-9\-]{3,})\s+service\b', r'`\1` service'),  # service references
        ]
        
        for pattern, replacement in entity_patterns:
            text = re.sub(pattern, replacement, text, flags=re.IGNORECASE)
            
        return text

    @keyword
    def calculate_log_health_score(self, scan_results: Dict[str, Any]) -> float:
        """Calculate a health score based on log scan results.
        
        Args:
            scan_results: Results from log scanning
            
        Returns:
            Health score between 0.0 (unhealthy) and 1.0 (healthy)
        """
        issues = scan_results.get('issues', [])
        
        if not issues:
            return 1.0
        
        # Calculate score based on severity levels
        critical_issues = sum(1 for issue in issues if issue.get('severity', 5) <= 2)
        warning_issues = sum(1 for issue in issues if issue.get('severity', 5) == 3)
        info_issues = sum(1 for issue in issues if issue.get('severity', 5) >= 4)
        
        # Weight the issues (critical issues heavily impact score)
        total_weight = (critical_issues * 10) + (warning_issues * 3) + (info_issues * 1)
        
        if critical_issues > 0:
            return 0.0  # Any critical issue results in unhealthy
        elif warning_issues > 0:
            return max(0.5, 1.0 - (total_weight * 0.1))  # Degraded health
        else:
            return max(0.8, 1.0 - (total_weight * 0.05))  # Minor issues

    @keyword
    def cleanup_temp_files(self):
        """Clean up temporary files created during log analysis."""
        if self.temp_dir and os.path.exists(self.temp_dir):
            import shutil
            try:
                shutil.rmtree(self.temp_dir)
                self.temp_dir = None
                logger.info("Cleaned up temporary log analysis files")
            except Exception as e:
                logger.warn(f"Failed to cleanup temporary files: {str(e)}") 