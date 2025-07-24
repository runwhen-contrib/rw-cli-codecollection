#!/usr/bin/env python3

import os
import json
import re
from pathlib import Path
import subprocess
import tempfile
from robot.api.deco import keyword, library
from robot.api import logger
from typing import Dict, List, Any, Optional, Tuple
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
        
        # Copy scan script to log directory
        source_dir = Path(__file__).parent.parent.parent.parent / "codebundles" / "k8s-application-log-health"
        scan_script = source_dir / "scan_logs.py"
        dest_script = Path(log_dir) / "scan_logs.py"
        dest_script.write_text(scan_script.read_text())
        os.chmod(dest_script, 0o755)
        
        # Set environment for scanning
        env = os.environ.copy()
        env.update({
            'WORKLOAD_TYPE': workload_type,
            'WORKLOAD_NAME': workload_name,
            'NAMESPACE': namespace,
            'CATEGORIES': ','.join(categories),
            'ISSUE_FILE': 'scan_results.json',
            'ERROR_JSON': 'error_patterns.json'
        })
        
        try:
            # Run the consolidated scan
            result = subprocess.run(['python3', 'scan_logs.py'], cwd=log_dir, env=env,
                                  capture_output=True, text=True, timeout=180)
            
            if result.returncode != 0:
                logger.warn(f"Log scanning completed with warnings: {result.stderr}")
            
            # Read results
            results_file = Path(log_dir) / "scan_results.json"
            if results_file.exists():
                with open(results_file, 'r') as f:
                    scan_results = json.load(f)
            else:
                scan_results = {"issues": [], "summary": ["No issues found."]}
            
            logger.info(f"Completed log scanning for {workload_type}/{workload_name}. Found {len(scan_results.get('issues', []))} issues.")
            return scan_results
            
        except subprocess.TimeoutExpired:
            raise RuntimeError("Log scanning timed out after 3 minutes")
        except Exception as e:
            raise RuntimeError(f"Error during log scanning: {str(e)}")

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
        # Copy anomaly detection script
        source_dir = Path(__file__).parent.parent.parent.parent / "codebundles" / "k8s-application-log-health"
        anomaly_script = source_dir / "scan_log_anomalies.sh"
        dest_script = Path(log_dir) / "scan_log_anomalies.sh"
        
        if anomaly_script.exists():
            dest_script.write_text(anomaly_script.read_text())
            os.chmod(dest_script, 0o755)
        
        env = os.environ.copy()
        env.update({
            'WORKLOAD_TYPE': workload_type,
            'WORKLOAD_NAME': workload_name,
            'NAMESPACE': namespace,
            'ISSUE_FILE': 'anomaly_results.json',
            'CATEGORIES': 'Anomaly'
        })
        
        try:
            result = subprocess.run(['./scan_log_anomalies.sh'], cwd=log_dir, env=env,
                                  capture_output=True, text=True, timeout=180)
            
            # Read anomaly results
            results_file = Path(log_dir) / "anomaly_results.json"
            if results_file.exists():
                with open(results_file, 'r') as f:
                    return json.load(f)
            else:
                return {"issues": [], "summary": ["No anomalies detected."]}
                
        except Exception as e:
            logger.warn(f"Anomaly analysis failed: {str(e)}")
            return {"issues": [], "summary": [f"Anomaly analysis failed: {str(e)}"]}

    @keyword
    def summarize_log_issues(self, issue_details: str) -> str:
        """Create a readable summary of log issues using the summarize script.
        
        Args:
            issue_details: Raw issue details to summarize
            
        Returns:
            Summarized and formatted issue details with full log content
        """
        if not self.temp_dir:
            self.temp_dir = tempfile.mkdtemp(prefix="k8s_log_analysis_")
        
        # Copy summarize script
        source_dir = Path(__file__).parent.parent.parent.parent / "codebundles" / "k8s-application-log-health"
        summarize_script = source_dir / "summarize.py"
        dest_script = Path(self.temp_dir) / "summarize.py"
        dest_script.write_text(summarize_script.read_text())
        os.chmod(dest_script, 0o755)
        
        # Write issue details to temp file
        details_file = Path(self.temp_dir) / "issue_details.txt"
        details_file.write_text(str(issue_details))
        
        try:
            result = subprocess.run(['python3', 'summarize.py'], 
                                  cwd=self.temp_dir, 
                                  input=issue_details, 
                                  capture_output=True, text=True, timeout=60)
            
            if result.returncode == 0:
                # Return the full summarized content without truncation
                return result.stdout
            else:
                logger.warn(f"Summary generation failed: {result.stderr}")
                # Return the full issue details without truncation
                return str(issue_details)
                
        except Exception as e:
            logger.warn(f"Summary generation error: {str(e)}")
            # Return the full issue details without truncation
            return str(issue_details)
    
    @keyword
    def format_scan_results_for_display(self, scan_results: Dict[str, Any]) -> str:
        """Format scan results into a readable display string to avoid serialization issues.
        
        Args:
            scan_results: Dictionary containing scan results
            
        Returns:
            Formatted string representation of the results
        """
        if not scan_results:
            return "No scan results available"
        
        # Handle string input (in case scan_results was already serialized)
        if isinstance(scan_results, str):
            try:
                scan_results = json.loads(scan_results)
            except json.JSONDecodeError:
                return f"Unable to parse scan results: {scan_results[:200]}..."
            
        issues = scan_results.get('issues', [])
        if not issues:
            summary = scan_results.get('summary', [])
            summary_text = "\n".join(summary) if summary else "No issues found in logs"
            return f"✅ No log issues detected.\n{summary_text}"
        
        output_parts = []
        output_parts.append("📋 **Log Issues Found:**")
        output_parts.append("=" * 40)
        
        for i, issue in enumerate(issues, 1):
            # Safely extract issue data
            title = self._safe_get(issue, 'title', 'Unknown Issue')
            severity_label = self._safe_get(issue, 'severity_label', 'Unknown')
            occurrences = self._safe_get(issue, 'occurrences', 1)
            category = self._safe_get(issue, 'category', 'Unknown')
            
            output_parts.append(f"\n**Issue {i}: {title}**")
            output_parts.append(f"  • Severity: {severity_label}")
            output_parts.append(f"  • Category: {category}")
            output_parts.append(f"  • Occurrences: {occurrences}")
            
            # Add sample details (truncated for readability)
            details = self._safe_get(issue, 'details', '')
            if details:
                # Extract first meaningful line as sample
                sample_line = self._extract_sample_line(details)
                if sample_line:
                    output_parts.append(f"  • Sample: {sample_line}")
            
            # Add context sample
            context_sample = self._extract_context_sample(details)
            if context_sample:
                output_parts.append("  • Context:")
                for line in context_sample:
                    output_parts.append(f"    {line}")
            
            # Add service-specific next steps if available
            next_steps = self._safe_get(issue, 'next_steps', '')
            if next_steps:
                # Extract service-specific guidance
                service_steps = self._extract_service_steps(next_steps)
                if service_steps:
                    output_parts.append(f"  • Key Actions: {service_steps}")
        
        return "\n".join(output_parts)
    
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
            if line.startswith("Context (5 lines before/after):"):
                in_context = True
                continue
            elif in_context and line == "":
                in_context = False
                break
            elif in_context and line:
                context_lines.append(line)
        
        # Return first few context lines if available
        if context_lines:
            return context_lines[:6]  # Show up to 6 context lines
        return []
    
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