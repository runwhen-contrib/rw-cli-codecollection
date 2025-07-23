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
            Summarized and formatted issue details
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
                return result.stdout
            else:
                logger.warn(f"Summary generation failed: {result.stderr}")
                return str(issue_details)[:1000] + "..." if len(str(issue_details)) > 1000 else str(issue_details)
                
        except Exception as e:
            logger.warn(f"Summary generation error: {str(e)}")
            return str(issue_details)[:1000] + "..." if len(str(issue_details)) > 1000 else str(issue_details)
    
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
            
        issues = scan_results.get('issues', [])
        if not issues:
            return "✅ No issues found in logs"
        
        output_parts = []
        output_parts.append("📋 **Log Issues Found:**")
        output_parts.append("=" * 40)
        
        for i, issue in enumerate(issues, 1):
            title = issue.get('title', 'Unknown Issue')
            severity_label = issue.get('severity_label', 'Unknown')
            occurrences = issue.get('occurrences', 1)
            category = issue.get('category', 'Unknown')
            
            output_parts.append(f"\n**Issue {i}: {title}**")
            output_parts.append(f"  • Severity: {severity_label}")
            output_parts.append(f"  • Category: {category}")
            output_parts.append(f"  • Occurrences: {occurrences}")
            
            # Add sample details (truncated for readability)
            details = issue.get('details', '')
            if details:
                # Extract first meaningful line as sample
                lines = details.split('\n')
                sample_line = None
                for line in lines:
                    line = line.strip()
                    if line and not line.startswith('Pod:') and not line.startswith('**'):
                        sample_line = line[:100] + "..." if len(line) > 100 else line
                        break
                
                if sample_line:
                    output_parts.append(f"  • Sample: {sample_line}")
        
        return "\n".join(output_parts)

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