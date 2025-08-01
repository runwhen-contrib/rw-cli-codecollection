#!/usr/bin/env python3

import os
import json
import re
import signal
from pathlib import Path
import subprocess
import tempfile
from robot.api.deco import keyword, library
from robot.api import logger
from typing import Dict, List, Any, Optional, Tuple, Union
from collections import defaultdict
from difflib import SequenceMatcher
from RW import platform


class TimeoutError(Exception):
    """Custom timeout exception for log scanning operations."""
    pass


def timeout_handler(signum, frame):
    """Signal handler for timeout operations."""
    raise TimeoutError("Log scanning operation timed out")


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
                },
                {
                    "name": "healthy_error_counts",
                    "pattern": r"(?i)(?:[a-zA-Z_\-]*errors?|[a-zA-Z_\-]*warnings?|[a-zA-Z_\-]*issues?|[a-zA-Z_\-]*problems?|[a-zA-Z_\-]*failures?|[a-zA-Z_\-]*alerts?)\s*[:=]\s*(?:\[\]|0|""|''|null|none|false)\s*$",
                    "description": "Healthy state indicators showing empty/zero error counts",
                    "exclude": True
                },
                {
                    "name": "healthy_error_counts_with_comma",
                    "pattern": r"(?i)(?:[a-zA-Z_\-]*errors?|[a-zA-Z_\-]*warnings?|[a-zA-Z_\-]*issues?|[a-zA-Z_\-]*problems?|[a-zA-Z_\-]*failures?|[a-zA-Z_\-]*alerts?)\s*[:=]\s*(?:\[\]|0|""|''|null|none|false)\s*,",
                    "description": "Healthy state indicators followed by comma",
                    "exclude": True
                },
                {
                    "name": "healthy_error_counts_with_brace",
                    "pattern": r"(?i)(?:[a-zA-Z_\-]*errors?|[a-zA-Z_\-]*warnings?|[a-zA-Z_\-]*issues?|[a-zA-Z_\-]*problems?|[a-zA-Z_\-]*failures?|[a-zA-Z_\-]*alerts?)\s*[:=]\s*(?:\[\]|0|""|''|null|none|false)\s*[}\]]",
                    "description": "Healthy state indicators followed by closing brace/bracket",
                    "exclude": True
                },
                {
                    "name": "healthy_error_counts_empty_string",
                    "pattern": r"(?i)(?:[a-zA-Z_\-]*errors?|[a-zA-Z_\-]*warnings?|[a-zA-Z_\-]*issues?|[a-zA-Z_\-]*problems?|[a-zA-Z_\-]*failures?|[a-zA-Z_\-]*alerts?)\s*[:=]\s*""\s*$",
                    "description": "Healthy state indicators with empty string at end of line",
                    "exclude": True
                },
                {
                    "name": "healthy_error_counts_empty_object",
                    "pattern": r"(?i)(?:[a-zA-Z_\-]*errors?|[a-zA-Z_\-]*warnings?|[a-zA-Z_\-]*issues?|[a-zA-Z_\-]*problems?|[a-zA-Z_\-]*failures?|[a-zA-Z_\-]*alerts?)\s*[:=]\s*\{\}\s*$",
                    "description": "Healthy state indicators with empty object at end of line",
                    "exclude": True
                },
                {
                    "name": "healthy_error_arrays",
                    "pattern": r'(?i)"(?:[a-zA-Z_\-]*errors?|[a-zA-Z_\-]*warnings?|[a-zA-Z_\-]*issues?|[a-zA-Z_\-]*problems?|[a-zA-Z_\-]*failures?|[a-zA-Z_\-]*alerts?)"\s*:\s*(?:\[\]|0|""|''|null|none|false)(?!\\s*[^\\s,}\\]])',
                    "description": "JSON-style healthy error arrays and counts",
                    "exclude": True
                },
                {
                    "name": "healthy_status_reports",
                    "pattern": r"(?i)(?:status|state|condition).*[:=]\s*(?:ok|success|healthy|ready|normal|good|pass)",
                    "description": "Healthy status reports",
                    "exclude": True
                },
                {
                    "name": "healthy_metric_reports",
                    "pattern": r"(?i)(?:metric|count|total).*[:=]\s*(?:0|zero|none|empty)",
                    "description": "Healthy metric reports showing zero counts",
                    "exclude": True
                },
                {
                    "name": "healthy_validation_results",
                    "pattern": r"(?i)(?:validation|check|test).*[:=]\s*(?:passed|success|ok|valid|true)",
                    "description": "Successful validation and test results",
                    "exclude": True
                },
                {
                    "name": "healthy_connection_reports",
                    "pattern": r"(?i)(?:connection|connect).*[:=]\s*(?:established|connected|active|ok)",
                    "description": "Successful connection reports",
                    "exclude": True
                },
                {
                    "name": "healthy_operation_results",
                    "pattern": r"(?i)(?:operation|action|task).*[:=]\s*(?:completed|success|done|finished)",
                    "description": "Successful operation completions",
                    "exclude": True
                },
                {
                    "name": "healthy_resource_reports",
                    "pattern": r"(?i)(?:resource|memory|cpu|disk).*[:=]\s*(?:available|sufficient|ok|normal)",
                    "description": "Healthy resource availability reports",
                    "exclude": True
                },
                {
                    "name": "healthy_service_reports",
                    "pattern": r"(?i)(?:service|endpoint|api).*[:=]\s*(?:up|running|available|healthy|ok)",
                    "description": "Healthy service status reports",
                    "exclude": True
                },
                {
                    "name": "healthy_database_reports",
                    "pattern": r"(?i)(?:database|db|query).*[:=]\s*(?:connected|active|ok|success)",
                    "description": "Healthy database connection reports",
                    "exclude": True
                },
                {
                    "name": "healthy_cache_reports",
                    "pattern": r"(?i)(?:cache|redis|memcached).*[:=]\s*(?:hit|available|connected|ok)",
                    "description": "Healthy cache operation reports",
                    "exclude": True
                },
                {
                    "name": "healthy_queue_reports",
                    "pattern": r"(?i)(?:queue|message|job).*[:=]\s*(?:empty|processed|completed|ok)",
                    "description": "Healthy queue and message processing reports",
                    "exclude": True
                },
                {
                    "name": "healthy_backup_reports",
                    "pattern": r"(?i)(?:backup|snapshot|archive).*[:=]\s*(?:completed|success|ok|finished)",
                    "description": "Successful backup and snapshot reports",
                    "exclude": True
                },
                {
                    "name": "healthy_deployment_reports",
                    "pattern": r"(?i)(?:deployment|release|version).*[:=]\s*(?:success|completed|active|ok)",
                    "description": "Successful deployment and release reports",
                    "exclude": True
                },
                {
                    "name": "healthy_monitoring_reports",
                    "pattern": r"(?i)(?:monitor|watch|observe).*[:=]\s*(?:normal|ok|healthy|stable)",
                    "description": "Normal monitoring and observation reports",
                    "exclude": True
                },
                {
                    "name": "healthy_cleanup_reports",
                    "pattern": r"(?i)(?:cleanup|garbage|maintenance).*[:=]\s*(?:completed|success|ok|finished)",
                    "description": "Successful cleanup and maintenance reports",
                    "exclude": True
                },
                {
                    "name": "healthy_sync_reports",
                    "pattern": r"(?i)(?:sync|replication|copy).*[:=]\s*(?:completed|success|ok|finished)",
                    "description": "Successful synchronization reports",
                    "exclude": True
                },
                {
                    "name": "healthy_auth_reports",
                    "pattern": r"(?i)(?:auth|authentication|authorization).*[:=]\s*(?:success|valid|ok|granted)",
                    "description": "Successful authentication reports",
                    "exclude": True
                },
                {
                    "name": "healthy_ssl_reports",
                    "pattern": r"(?i)(?:ssl|tls|certificate).*[:=]\s*(?:valid|ok|success|verified)",
                    "description": "Successful SSL/TLS certificate reports",
                    "exclude": True
                },
                {
                    "name": "healthy_timeout_reports",
                    "pattern": r"(?i)(?:timeout|deadline).*[:=]\s*(?:none|0|disabled|false)",
                    "description": "Disabled or zero timeout configurations",
                    "exclude": True
                },
                {
                    "name": "azure_servicebus_connection_recovery",
                    "pattern": r"(?i).*(?:onLinkRemoteOpen|onConnectionBound|Emitting new response channel).*(?:connectionId|linkName|entityPath)",
                    "description": "Azure Service Bus normal connection establishment and recovery",
                    "exclude": True
                },
                {
                    "name": "azure_servicebus_idle_timeout_recovery",
                    "pattern": r"(?i).*(?:IdleTimerExpired|Idle timeout|Transient error occurred).*(?:retryAfter|attempt)",
                    "description": "Azure Service Bus normal idle timeout and automatic retry",
                    "exclude": True
                },
                {
                    "name": "azure_servicebus_link_lifecycle",
                    "pattern": r"(?i).*(?:Freeing resources due to error|link.*is force detached)",
                    "description": "Azure Service Bus normal link lifecycle and cleanup",
                    "exclude": True
                },
                {
                    "name": "azure_servicebus_reactor_disposal",
                    "pattern": r"(?i).*Reactor selectable is being disposed.*connectionId",
                    "description": "Azure Service Bus normal reactor cleanup",
                    "exclude": True
                },
                {
                    "name": "azure_cosmosdb_connection_establishment",
                    "pattern": r"(?i).*Getting database account endpoint from.*\.documents\.azure\.com",
                    "description": "Azure Cosmos DB normal connection establishment",
                    "exclude": True
                }
            ],
            "patterns": {
                "GenericError": [
                    {
                        "name": "generic_error",
                        "pattern": r"(?i)\b(error|err|exception|fail|fatal|panic|crash|abort)\b",
                        "severity": 2,
                        "next_steps": ["Extract specific error details from logs", "Identify the failing component or service", "Check for related errors in the same time window"]
                    }
                ],
                "Connection": [
                    {
                        "name": "connection_refused",
                        "pattern": r"(?i)(connection\s+refused|connect.*refused|refused.*connection)",
                        "severity": 2,
                        "next_steps": ["Verify target service is running and healthy", "Check if service ports are accessible", "Validate network policies and firewall rules", "Inspect service discovery configuration"]
                    },
                    {
                        "name": "connection_timeout",
                        "pattern": r"(?i)(connection\s+timeout|timeout.*connection|connect.*timeout)",
                        "severity": 2,
                        "next_steps": ["Check target service response times and load", "Verify network connectivity between services", "Review timeout configuration for calling service", "Inspect service mesh or proxy settings"]
                    }
                ],
                "Auth": [
                    {
                        "name": "authentication_failed",
                        "pattern": r"(?i)(auth.*fail|authentication.*fail|unauthorized|401|403|forbidden)",
                        "severity": 2,
                        "next_steps": ["Verify service account tokens and certificates", "Check RBAC permissions for the service", "Validate authentication provider configuration", "Review API key or credential expiration"]
                    }
                ],
                "Timeout": [
                    {
                        "name": "timeout_error",
                        "pattern": r"(?i)(timeout|timed\s+out|deadline\s+exceeded)",
                        "severity": 2,
                        "next_steps": ["Identify which operation is timing out", "Check downstream service performance", "Review timeout values in configuration", "Monitor resource utilization during timeouts"]
                    }
                ],
                "Resource": [
                    {
                        "name": "out_of_memory",
                        "pattern": r"(?i)(out\s+of\s+memory|oom|memory.*exhausted|killed.*memory)",
                        "severity": 1,
                        "next_steps": ["Increase memory limits for the container", "Analyze memory usage patterns and leaks", "Review garbage collection settings", "Consider horizontal scaling if memory usage is consistently high"]
                    }
                ],
                "AppFailure": [
                    {
                        "name": "application_startup_failure",
                        "pattern": r"(?i)(startup.*fail|failed.*start|application.*fail|service.*fail)",
                        "severity": 2,
                        "next_steps": ["Check environment variables and configuration files", "Verify required dependencies are available", "Review container image and startup command", "Check for missing secrets or configmaps"]
                    }
                ],
                "StackTrace": [
                    {
                        "name": "stack_trace",
                        "pattern": r"(?i)(stack\s+trace|stacktrace|traceback|at\s+.*\.java:|at\s+.*\.py:|at\s+.*\.js:)",
                        "severity": 3,
                        "next_steps": ["Identify the root cause from the stack trace", "Check the specific line of code that failed", "Verify input data and request parameters", "Review recent code changes that might have introduced the issue"]
                    }
                ],
                "Exceptions": [
                    {
                        "name": "null_pointer_exception",
                        "pattern": r"(?i)(nullpointerexception|null\s+pointer|nullptr|segmentation\s+fault)",
                        "severity": 2,
                        "next_steps": ["Add null checks in the failing code path", "Verify object initialization order", "Check for race conditions in concurrent code", "Review request data validation"]
                    }
                ],
                "HealthyRecovery": [
                    {
                        "name": "azure_servicebus_connection_recovery",
                        "pattern": r"(?i).*(?:onLinkRemoteOpen|onConnectionBound|Emitting new response channel).*(?:connectionId|linkName|entityPath)",
                        "severity": 5,
                        "next_steps": ["This is normal Azure Service Bus connection recovery behavior", "No action required - connections are re-establishing automatically", "Monitor for excessive connection churn if this occurs very frequently"]
                    },
                    {
                        "name": "azure_servicebus_idle_timeout_recovery",
                        "pattern": r"(?i).*(?:IdleTimerExpired|Idle timeout|Transient error occurred).*(?:retryAfter|attempt)",
                        "severity": 5,
                        "next_steps": ["This is normal Azure Service Bus idle timeout recovery", "Connections idle for 10+ minutes are automatically cleaned up and recreated", "No action required - automatic retry is functioning correctly"]
                    },
                    {
                        "name": "azure_servicebus_link_lifecycle",
                        "pattern": r"(?i).*(?:Freeing resources due to error|link.*is force detached)",
                        "severity": 5,
                        "next_steps": ["This is normal Azure Service Bus link lifecycle management", "Links are cleaned up after idle timeout and recreated as needed", "No action required - this indicates healthy connection management"]
                    },
                    {
                        "name": "azure_servicebus_reactor_disposal",
                        "pattern": r"(?i).*Reactor selectable is being disposed.*connectionId",
                        "severity": 5,
                        "next_steps": ["This is normal Azure Service Bus reactor cleanup", "Old connections are being properly disposed", "No action required - this indicates proper resource cleanup"]
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

    def _convert_sli_patterns_format(self, sli_data: Dict[str, Any]) -> Dict[str, Any]:
        """Convert sli_critical_patterns.json format to internal format."""
        patterns = {}
        
        for category, category_data in sli_data.get('critical_patterns', {}).items():
            patterns[category] = []
            for pattern_str in category_data.get('patterns', []):
                patterns[category].append({
                    'name': f"{category.lower()}_pattern",
                    'pattern': pattern_str,
                    'severity': category_data.get('severity', 2),
                    'next_steps': [f"Investigate {category.lower()} issue", "Review application logs", "Check application configuration"]
                })
        
        return {
            'patterns': patterns,
            'infrastructure_filters': self.error_patterns.get('infrastructure_filters', [])
        }

    def _generate_context_aware_next_steps(self, pattern_name: str, base_next_steps: List[str], 
                                          sample_lines: List[str], workload_name: str, namespace: str) -> List[str]:
        """Generate context-aware next steps based on log content and extracted entities."""
        if not sample_lines:
            return base_next_steps
            
        context_steps = []
        first_sample = sample_lines[0]
        
        # Extract specific entities from the log line
        service_names = set()
        ports = set()
        error_codes = set()
        operations = set()
        
        # Extract service names - be more selective to avoid action words
        service_patterns = [
            # Pattern for "failed to retrieve cart" -> "cart"
            r'(?:could not|failed to|unable to)\s+(?:retrieve|get|fetch|add to)\s+([a-zA-Z][a-zA-Z0-9\-]{3,15})(?:\s|:|$)',
            # Pattern for "cartservice" or "cart-service"  
            r'([a-zA-Z][a-zA-Z0-9\-]{3,15})(?:service|svc)(?:\s|:|$)',
            # Pattern for RPC errors with service names
            r'rpc error.*?service["\s]+([a-zA-Z][a-zA-Z0-9\-]{3,15})(?:\s|"|$)',
            # Pattern for dial tcp errors
            r'dial tcp.*?([a-zA-Z][a-zA-Z0-9\-]{3,15})(?:\.|:)'
        ]
        
        # Words that are definitely not service names
        excluded_words = {
            'connect', 'connection', 'retrieve', 'get', 'fetch', 'add', 'to', 'from', 'with',
            'http', 'https', 'tcp', 'grpc', 'error', 'code', 'desc', 'rpc', 'dial', 'failed',
            'could', 'not', 'unable', 'service', 'server', 'client', 'request', 'response',
            'timeout', 'refused', 'closed', 'reset', 'abort', 'cancel', 'retry', 'attempt'
        }
        
        for pattern in service_patterns:
            matches = re.findall(pattern, first_sample, re.IGNORECASE)
            for match in matches:
                match_lower = match.lower().strip()
                # Only add if it's not an excluded word and looks like a service name
                if (match_lower not in excluded_words and 
                    len(match_lower) >= 3 and 
                    len(match_lower) <= 15 and
                    not match_lower.isdigit() and
                    # Must contain letters (not just numbers/symbols)
                    re.search(r'[a-zA-Z]{2,}', match_lower)):
                    service_names.add(match_lower)
        
        # Extract ports
        port_matches = re.findall(r':(\d{4,5})', first_sample)
        ports.update(port_matches)
        
        # Extract error codes
        error_code_matches = re.findall(r'code\s*=\s*([A-Z_]+)', first_sample, re.IGNORECASE)
        error_codes.update(error_code_matches)
        
        # Extract operations - be more selective
        op_matches = re.findall(r'(?:could not|failed to|unable to)\s+([\w\s]+?)(?:\s*:|from|with|to\s+\w+|$)', first_sample, re.IGNORECASE)
        for op in op_matches:
            op_clean = op.strip()
            # Only include meaningful operations, exclude single words that are likely service names
            if (len(op_clean) > 3 and len(op_clean) < 25 and 
                ' ' in op_clean and  # Must be multi-word to be an operation
                not op_clean.lower().startswith(('connect', 'connection'))):
                operations.add(op_clean)
        
                 # Generate specific steps based on pattern type and extracted entities
        if 'connection' in pattern_name.lower():
            if service_names:
                for service in list(service_names)[:2]:  # Limit to 2 services
                    context_steps.append(f"Verify `{service}` service is running and healthy")
                    context_steps.append(f"Check `{service}` service endpoints and port availability")
                    if ports:
                        port = list(ports)[0]
                        context_steps.append(f"Test network connectivity to `{service}` service on port `{port}`")
            
            if error_codes:
                for code in list(error_codes)[:2]:
                    if code.upper() == 'UNAVAILABLE':
                        context_steps.append(f"Service unavailable - check deployment status and replica count")
                    elif code.upper() == 'DEADLINE_EXCEEDED':
                        context_steps.append(f"Request timeout - review service performance and timeout configurations")
                        
        elif 'auth' in pattern_name.lower():
            context_steps.append(f"Verify service account permissions for `{workload_name}` deployment")
            context_steps.append(f"Check RBAC configuration for service account in `{namespace}` namespace")
            if '401' in first_sample or '403' in first_sample:
                context_steps.append(f"Review authentication tokens and certificates for `{workload_name}` deployment")
                
        elif 'timeout' in pattern_name.lower():
            if operations:
                op = list(operations)[0]
                context_steps.append(f"Investigate timeout for operation: '{op}'")
            if service_names:
                service = list(service_names)[0]
                context_steps.append(f"Check `{service}` service response times and performance metrics")
                context_steps.append(f"Review `{service}` service logs for performance bottlenecks")
                
        elif 'memory' in pattern_name.lower() or 'oom' in pattern_name.lower():
            context_steps.append(f"Check current memory usage for `{workload_name}` deployment")
            context_steps.append(f"Review memory limits and requests for `{workload_name}` deployment")
            context_steps.append(f"Consider increasing memory allocation for `{workload_name}` containers")
            
        elif 'stack' in pattern_name.lower() or 'exception' in pattern_name.lower():
            # Extract file/line info from stack traces
            stack_matches = re.findall(r'at\s+.*?\.(?:java|py|js):(\d+)', first_sample)
            if stack_matches:
                line_num = stack_matches[0]
                context_steps.append(f"Review application code at line `{line_num}` for the root cause")
            
            # Extract method names
            method_matches = re.findall(r'at\s+[\w.]+\.(\w+)\(', first_sample)
            if method_matches:
                method = method_matches[0]
                context_steps.append(f"Investigate `{method}()` method for null pointer or logic errors")
        
        # Add generic context-aware steps
        if service_names:
            services_list = "`, `".join(list(service_names)[:3])
            context_steps.append(f"Monitor health and availability of related services: `{services_list}`")
            
        # Combine context-aware steps with base steps (context-aware first)
        final_steps = context_steps + base_next_steps
        
        # Remove duplicates while preserving order
        seen = set()
        unique_steps = []
        for step in final_steps:
            if step not in seen:
                seen.add(step)
                unique_steps.append(step)
                
        return unique_steps[:6]  # Limit to 6 steps to avoid overwhelming output

    def _generate_issue_title(self, workload_type: str, workload_name: str, sample_lines: List[str]) -> str:
        """Generate a descriptive title based on the error content."""
        title = f"Application Log: Error pattern detected in {workload_type} `{workload_name}`"
        
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
                title = f"Application Log: `{service_name}` service errors in {workload_type} `{workload_name}` - \"{error_snippet}...\""
            else:
                # Extract error type for more specific title
                if 'connection refused' in error_msg.lower():
                    error_snippet = error_msg[:40].strip()
                    title = f"Application Log: Connection refused errors in {workload_type} `{workload_name}` - \"{error_snippet}...\""
                elif 'timeout' in error_msg.lower():
                    error_snippet = error_msg[:40].strip()
                    title = f"Application Log: Timeout errors in {workload_type} `{workload_name}` - \"{error_snippet}...\""
                elif 'rpc error' in error_msg.lower():
                    error_snippet = error_msg[:40].strip()
                    title = f"Application Log: RPC communication errors in {workload_type} `{workload_name}` - \"{error_snippet}...\""
                elif 'authentication' in error_msg.lower() or 'auth' in error_msg.lower():
                    error_snippet = error_msg[:40].strip()
                    title = f"Application Log: Authentication errors in {workload_type} `{workload_name}` - \"{error_snippet}...\""
                elif 'permission' in error_msg.lower() or 'forbidden' in error_msg.lower():
                    error_snippet = error_msg[:40].strip()
                    title = f"Application Log: Permission/authorization errors in {workload_type} `{workload_name}` - \"{error_snippet}...\""
                elif 'not found' in error_msg.lower() or '404' in error_msg:
                    error_snippet = error_msg[:40].strip()
                    title = f"Application Log: Resource not found errors in {workload_type} `{workload_name}` - \"{error_snippet}...\""
                elif 'database' in error_msg.lower() or 'db' in error_msg.lower():
                    error_snippet = error_msg[:40].strip()
                    title = f"Application Log: Database connection errors in {workload_type} `{workload_name}` - \"{error_snippet}...\""
                elif 'memory' in error_msg.lower() or 'out of memory' in error_msg.lower():
                    error_snippet = error_msg[:40].strip()
                    title = f"Application Log: Memory/resource exhaustion in {workload_type} `{workload_name}` - \"{error_snippet}...\""
                else:
                    # Use first part of error message for context
                    error_preview = error_msg[:40].strip()
                    if error_preview:
                        title = f"Application Log: Error pattern in {workload_type} `{workload_name}` - \"{error_preview}...\""
        else:
            # Fallback title with entity names in backticks
            title = f"Application Log: Error pattern detected in `{workload_name}`"
            
        return title

    def _get_ignore_patterns(self):
        """Get built-in ignore patterns for log filtering."""
        # Extract patterns from infrastructure_filters
        ignore_patterns = []
        for filter_config in self.error_patterns.get("infrastructure_filters", []):
            if filter_config.get("exclude", False):
                ignore_patterns.append(filter_config["pattern"])
        
        # Add legacy patterns for backward compatibility
        legacy_patterns = [
            "connection closed before message completed",
            "server idle timeout"
        ]
        
        return ignore_patterns + legacy_patterns

    def _get_pods_for_workload(self, workload_type: str, workload_name: str, 
                              namespace: str, context: str, kubeconfig_path: str) -> List[Dict]:
        """Get pods associated with a workload."""
        env = os.environ.copy()
        env['KUBECONFIG'] = kubeconfig_path
        
        # First, get the workload and extract its UID
        cmd = ['kubectl', 'get', workload_type, workload_name, 
               '-n', namespace, '--context', context, '-o', 'json']
        
        try:
            result = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=30)
            if result.returncode != 0:
                raise RuntimeError(f"Failed to get {workload_type}/{workload_name}: {result.stderr}")
                
            workload_data = json.loads(result.stdout)
            workload_uid = workload_data['metadata']['uid']
            
        except json.JSONDecodeError as e:
            raise RuntimeError(f"Failed to parse workload JSON: {e}")
        except Exception as e:
            raise RuntimeError(f"Error getting workload: {e}")
        
        # Get pods based on workload type
        if workload_type.lower() == 'deployment':
            # For deployments, get ReplicaSets first, then pods
            cmd = ['kubectl', 'get', 'replicaset', '-n', namespace, 
                   '--context', context, '-o', 'json']
            
            try:
                result = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=30)
                if result.returncode != 0:
                    raise RuntimeError(f"Failed to get ReplicaSets: {result.stderr}")
                    
                rs_data = json.loads(result.stdout)
                rs_uids = []
                
                # Find ReplicaSets owned by this deployment
                for rs in rs_data.get('items', []):
                    owner_refs = rs.get('metadata', {}).get('ownerReferences', [])
                    for owner in owner_refs:
                        if owner.get('uid') == workload_uid:
                            rs_uids.append(rs['metadata']['uid'])
                            break
                
                if not rs_uids:
                    return []
                
                # Get pods owned by these ReplicaSets
                cmd = ['kubectl', 'get', 'pods', '-n', namespace, 
                       '--context', context, '-o', 'json']
                       
                result = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=30)
                if result.returncode != 0:
                    raise RuntimeError(f"Failed to get pods: {result.stderr}")
                    
                pods_data = json.loads(result.stdout)
                matching_pods = []
                
                for pod in pods_data.get('items', []):
                    owner_refs = pod.get('metadata', {}).get('ownerReferences', [])
                    for owner in owner_refs:
                        if owner.get('uid') in rs_uids:
                            matching_pods.append(pod)
                            break
                            
                return matching_pods
                
            except json.JSONDecodeError as e:
                raise RuntimeError(f"Failed to parse JSON: {e}")
                
        else:
            # For StatefulSet/DaemonSet, pods are directly owned
            cmd = ['kubectl', 'get', 'pods', '-n', namespace, 
                   '--context', context, '-o', 'json']
                   
            try:
                result = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=30)
                if result.returncode != 0:
                    raise RuntimeError(f"Failed to get pods: {result.stderr}")
                    
                pods_data = json.loads(result.stdout)
                matching_pods = []
                
                for pod in pods_data.get('items', []):
                    owner_refs = pod.get('metadata', {}).get('ownerReferences', [])
                    for owner in owner_refs:
                        if owner.get('uid') == workload_uid:
                            matching_pods.append(pod)
                            break
                            
                return matching_pods
                
            except json.JSONDecodeError as e:
                raise RuntimeError(f"Failed to parse JSON: {e}")

    def _fetch_container_logs(self, pod_name: str, container_name: str, namespace: str, 
                            context: str, kubeconfig_path: str, log_age: str, 
                            max_log_lines: str, max_log_bytes: str, ignore_patterns: List[str]) -> str:
        """Fetch logs for a specific container and apply ignore patterns."""
        env = os.environ.copy()
        env['KUBECONFIG'] = kubeconfig_path
        
        logs_content = ""
        
        # Fetch current logs
        cmd = ['kubectl', 'logs', pod_name, '-c', container_name, '-n', namespace, 
               '--context', context, f'--since={log_age}', '--timestamps', 
               f'--tail={max_log_lines}', f'--limit-bytes={max_log_bytes}']
        
        try:
            result = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=60)
            if result.returncode == 0:
                logs_content += result.stdout
        except subprocess.TimeoutExpired:
            logger.warning(f"Timeout fetching current logs for {pod_name}/{container_name}")
        except Exception as e:
            logger.warning(f"Error fetching current logs for {pod_name}/{container_name}: {e}")
        
        # Fetch previous logs (if any)
        cmd_prev = cmd + ['--previous']
        try:
            result = subprocess.run(cmd_prev, env=env, capture_output=True, text=True, timeout=60)
            if result.returncode == 0:
                logs_content += result.stdout
        except subprocess.TimeoutExpired:
            logger.warning(f"Timeout fetching previous logs for {pod_name}/{container_name}")
        except Exception as e:
            # Previous logs might not exist, which is normal
            pass
        
        # Apply ignore patterns
        if ignore_patterns and logs_content:
            lines = logs_content.split('\n')
            filtered_lines = []
            
            for line in lines:
                should_ignore = False
                for pattern in ignore_patterns:
                    if pattern in line:
                        should_ignore = True
                        break
                
                if not should_ignore:
                    filtered_lines.append(line)
            
            logs_content = '\n'.join(filtered_lines)
        
        return logs_content

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
        
        try:
            # Get pods for the workload
            pods = self._get_pods_for_workload(workload_type, workload_name, namespace, context, kubeconfig_path)
            
            # Get ignore patterns
            ignore_patterns = self._get_ignore_patterns()
            
            # Create logs directory
            logs_dir = os.path.join(self.temp_dir, f"{workload_type}_{workload_name}_logs")
            os.makedirs(logs_dir, exist_ok=True)
            
            # Save pod information for analysis
            pods_file = os.path.join(self.temp_dir, "application_logs_pods.json")
            with open(pods_file, 'w') as f:
                json.dump(pods, f, indent=2)
            
            # Fetch logs for each pod/container
            for pod in pods:
                pod_name = pod['metadata']['name']
                logger.info(f"Processing Pod: {pod_name}")
                
                containers = pod.get('spec', {}).get('containers', [])
                for container in containers:
                    container_name = container['name']
                    logger.info(f"  Container: {container_name}")
                    
                    # Fetch logs for this container
                    logs_content = self._fetch_container_logs(
                        pod_name, container_name, namespace, context, kubeconfig_path,
                        log_age, max_log_lines, max_log_bytes, ignore_patterns
                    )
                    
                    # Save logs to file
                    log_file = os.path.join(logs_dir, f"{pod_name}_{container_name}_logs.txt")
                    with open(log_file, 'w') as f:
                        f.write(logs_content)
            
            logger.info(f"Successfully fetched logs for {workload_type}/{workload_name}")
            logger.info(f"Logs stored in: {logs_dir}")
            return self.temp_dir
            
        except Exception as e:
            raise RuntimeError(f"Error fetching logs: {str(e)}")

    @keyword
    def scan_logs_for_issues(self, log_dir: str, workload_type: str, workload_name: str, 
                           namespace: str, categories: List[str] = None, 
                           custom_patterns_file: str = None) -> Dict[str, Any]:
        """Scan fetched logs for various error patterns and issues.
        
        Args:
            log_dir: Directory containing the fetched logs
            workload_type: Type of workload
            workload_name: Name of the workload  
            namespace: Kubernetes namespace
            categories: List of categories to scan for (optional, defaults to all)
            custom_patterns_file: Path to custom error patterns JSON file (optional)
            
        Returns:
            Dictionary containing scan results with issues and summary
        """
        # Set up timeout handling
        timeout_seconds = int(os.environ.get('LOG_SCAN_TIMEOUT', '300'))  # Default 5 minutes
        signal.signal(signal.SIGALRM, timeout_handler)
        signal.alarm(timeout_seconds)
        
        try:
            return self._scan_logs_for_issues_impl(log_dir, workload_type, workload_name, 
                                                 namespace, categories, custom_patterns_file)
        except TimeoutError:
            logger.warning(f"Log scanning timed out after {timeout_seconds} seconds")
            return {
                "issues": [],
                "summary": [
                    f"Log scanning timed out after {timeout_seconds} seconds. "
                    f"Consider reducing LOG_AGE parameter or increasing LOG_SCAN_TIMEOUT. "
                    f"Large log files may cause timeouts."
                ]
            }
        except Exception as e:
            logger.error(f"Error during log scanning: {e}")
            return {
                "issues": [],
                "summary": [f"Error during log scanning: {str(e)}"]
            }
        finally:
            # Cancel the alarm
            signal.alarm(0)

    def _scan_logs_for_issues_impl(self, log_dir: str, workload_type: str, workload_name: str, 
                                 namespace: str, categories: List[str] = None, 
                                 custom_patterns_file: str = None) -> Dict[str, Any]:
        """Implementation of log scanning with timeout protection."""
        if categories is None:
            categories = [
                "GenericError", "AppFailure", "StackTrace", "Connection", 
                "Timeout", "Auth", "Exceptions", "Anomaly", "AppRestart", "Resource", "HealthyRecovery"
            ]
        
        # Use custom patterns if provided, otherwise use embedded patterns
        patterns_data = self.error_patterns
        if custom_patterns_file:
            try:
                with open(custom_patterns_file, 'r', encoding='utf-8') as f:
                    custom_data = json.load(f)
                    # Convert sli_critical_patterns.json format to internal format
                    if 'critical_patterns' in custom_data:
                        patterns_data = self._convert_sli_patterns_format(custom_data)
                    else:
                        patterns_data = custom_data
                logger.info(f"Loaded custom patterns from {custom_patterns_file}")
            except Exception as e:
                logger.warning(f"Failed to load custom patterns from {custom_patterns_file}: {e}")
                logger.info("Using embedded patterns as fallback")
        
        log_path = Path(log_dir)
        pods_json_path = log_path / "application_logs_pods.json"
        
        # Read the pods JSON
        try:
            with open(pods_json_path, "r", encoding="utf-8") as f:
                pods_data = json.load(f)
        except Exception as e:
            logger.warn(f"Error reading pods JSON: {e}")
            return {"issues": [], "summary": ["No pods data found for analysis."]}

        # Pre-compile all regex patterns for better performance
        compiled_patterns = {}
        for category in categories:
            if category not in patterns_data["patterns"]:
                continue
            compiled_patterns[category] = []
            for pattern_config in patterns_data["patterns"][category]:
                try:
                    compiled_pattern = re.compile(pattern_config["pattern"], re.IGNORECASE)
                    compiled_patterns[category].append({
                        "pattern": compiled_pattern,
                        "config": pattern_config
                    })
                except re.error as e:
                    logger.warning(f"Invalid regex pattern in {category}: {pattern_config['pattern']} - {e}")
                    continue

        # Pattern aggregators
        category_issues = defaultdict(list)
        category_notes = defaultdict(list)  # Track severity 5 items separately
        max_severity = 5

        # Map of numeric severity to text label
        severity_label_map = {
            1: "Critical",
            2: "Major", 
            3: "Minor",
            4: "Informational",
            5: "Note",
        }

        pods = [pod["metadata"]["name"] for pod in pods_data]
        logger.info(f"Scanning logs for {workload_type}/{workload_name} in namespace {namespace}...")

        # Performance optimization: Set limits for large log files
        max_lines_per_file = 50000  # Limit to 50k lines per file to prevent timeouts
        max_total_lines = 200000    # Limit total lines across all files
        total_lines_processed = 0

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

                # Check file size before processing
                try:
                    file_size = log_file.stat().st_size
                    if file_size > 50 * 1024 * 1024:  # 50MB limit
                        logger.warning(f"  Skipping large log file {log_file} ({file_size / 1024 / 1024:.1f}MB)")
                        continue
                except Exception as e:
                    logger.warning(f"  Could not check file size for {log_file}: {e}")
                    continue

                with open(log_file, "r", encoding="utf-8") as lf:
                    log_content = lf.read()

                # Skip if log content is empty or only contains "errors": []
                if not log_content.strip() or re.match(r'^\s*"errors":\s*\[\s*\]\s*$', log_content.strip()):
                    continue

                log_lines = log_content.split('\n')
                
                # Limit lines per file to prevent timeouts
                if len(log_lines) > max_lines_per_file:
                    logger.info(f"  Truncating large log file from {len(log_lines)} to {max_lines_per_file} lines")
                    log_lines = log_lines[:max_lines_per_file]
                
                # Check total lines limit
                if total_lines_processed + len(log_lines) > max_total_lines:
                    remaining_lines = max_total_lines - total_lines_processed
                    if remaining_lines > 0:
                        logger.info(f"  Reached total line limit, processing only {remaining_lines} more lines")
                        log_lines = log_lines[:remaining_lines]
                    else:
                        logger.info(f"  Reached total line limit, skipping remaining files")
                        break
                
                total_lines_processed += len(log_lines)
                
                # Process each category with optimized pattern matching
                for category in categories:
                    if category not in compiled_patterns:
                        continue
                        
                    patterns = compiled_patterns[category]
                    
                    for pattern_data in patterns:
                        pattern = pattern_data["pattern"]
                        pattern_config = pattern_data["config"]
                        severity = pattern_config["severity"]
                        next_steps = pattern_config["next_steps"]
                        
                        matches = []
                        # Optimized: Use list comprehension for better performance
                        for line_num, line in enumerate(log_lines, 1):
                            if pattern.search(line):
                                matches.append({
                                    "line_number": line_num,
                                    "line": line.strip(),
                                    "pod": pod,
                                    "container": container
                                })
                                # Limit matches per pattern to prevent memory issues
                                if len(matches) >= 100:
                                    break
                        
                        if matches:
                            # Only add to category_issues if severity is less than 5
                            if severity < 5:
                                max_severity = min(max_severity, severity)
                                
                                # Generate context-aware next steps
                                sample_lines = [m["line"] for m in matches[:3]]
                                context_aware_steps = self._generate_context_aware_next_steps(
                                    pattern_config["name"], next_steps, sample_lines, workload_name, namespace
                                )
                                
                                # Create issue for this pattern
                                issue = {
                                    "category": category,
                                    "pattern_name": pattern_config["name"],
                                    "severity": severity,
                                    "next_steps": context_aware_steps,
                                    "matches": matches,
                                    "total_occurrences": len(matches),
                                    "sample_lines": sample_lines
                                }
                                
                                category_issues[category].append(issue)
                            else:
                                # If severity is 5, add to category_notes
                                note = {
                                    "category": category,
                                    "pattern_name": pattern_config["name"],
                                    "severity": severity,
                                    "next_steps": next_steps, # Severity 5 items don't have specific next steps
                                    "matches": matches,
                                    "total_occurrences": len(matches),
                                    "sample_lines": [m["line"] for m in matches[:3]] # Sample lines for notes
                                }
                                category_notes[category].append(note)
            
            # Check if we've reached the total line limit
            if total_lines_processed >= max_total_lines:
                logger.info(f"Reached total line limit ({max_total_lines}), stopping processing")
                break

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
                container_info = defaultdict(int)
                for match in issue["matches"]:
                    container_info[match['container']] += 1
                
                details_part = f"**Container:** {', '.join([f'{container} ({count}x)' for container, count in container_info.items()])}"
                consolidated_data["details_parts"].append(details_part)

        # Create final issues from consolidated data (severity < 5 only)
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

        # Consolidate notes by category and create final results
        consolidated_notes_by_category = {}
        for category, notes in category_notes.items():
            consolidated_notes_by_category[category] = {
                "total_occurrences": sum(n["total_occurrences"] for n in notes),
                "sample_lines": list(dict.fromkeys([n["sample_lines"][0] for n in notes])), # Take one sample line per note
                "unique_next_steps": set(),
                "details_parts": []
            }
            for note in notes:
                consolidated_notes_by_category[category]["unique_next_steps"].update(note["next_steps"])
                # Add details about where the note was found
                container_info = defaultdict(int)
                for match in note["matches"]:
                    container_info[match['container']] += 1
                details_part = f"**Container:** {', '.join([f'{container} ({count}x)' for container, count in container_info.items()])}"
                consolidated_notes_by_category[category]["details_parts"].append(details_part)

        # Add notes to summary
        for category, note_data in consolidated_notes_by_category.items():
            if note_data["total_occurrences"] > 0:
                severity_label = severity_label_map.get(5, "Note") # Severity 5 is always "Note"
                issues_json["summary"].append(
                    f"📝 Informational Notes ({category} events): {note_data['total_occurrences']}x. "
                    f"These are normal operational events that do not require action."
                )

        # Generate summary
        total_issues = len(consolidated_issues)
        total_notes = sum(len(notes) for notes in consolidated_notes_by_category.values()) # Count total notes across all categories
        categories_found = set(issue_data["category"] for issue_data in consolidated_issues.values())
        note_categories_found = set(category for category in consolidated_notes_by_category.keys())
        
        severity_label = severity_label_map.get(max_severity, f"Unknown({max_severity})")
        
        # Add performance information to summary
        performance_info = f"Processed {total_lines_processed:,} total log lines"
        if total_lines_processed >= max_total_lines:
            performance_info += f" (limited to {max_total_lines:,} lines for performance)"
        
        issues_json["summary"].append(
            f"Found {total_issues} issue patterns in {workload_type} '{workload_name}' (ns: {namespace}). "
            f"Max severity: {severity_label}. Categories: {', '.join(sorted(categories_found))}. {performance_info}."
        )

        if not consolidated_issues:
            issues_json["summary"].append(
                f"No issues found in {workload_type} '{workload_name}' (namespace '{namespace}'). {performance_info}."
            )

        logger.info(f"Completed log scanning for {workload_type}/{workload_name}. Found {len(issues_json.get('issues', []))} issues. {performance_info}")
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
                        
                        # Generate context-aware next steps for anomalies
                        context_steps = []
                        
                        # Analyze the repeated message for specific guidance
                        if 'connection' in cleaned_line.lower() and ('refused' in cleaned_line.lower() or 'timeout' in cleaned_line.lower()):
                            context_steps.append(f"Connection issues detected - verify network connectivity to target services")
                            context_steps.append(f"Check health status of downstream services")
                        elif 'error' in cleaned_line.lower() and 'rpc' in cleaned_line.lower():
                            context_steps.append(f"RPC communication failures - investigate service mesh or proxy configuration")
                            context_steps.append(f"Verify service discovery and endpoint configuration")
                        elif 'memory' in cleaned_line.lower() or 'oom' in cleaned_line.lower():
                            context_steps.append(f"Memory pressure detected - review resource limits for `{container}` container")
                            context_steps.append(f"Analyze memory usage patterns for `{container}` container")
                        elif 'auth' in cleaned_line.lower() or '401' in cleaned_line or '403' in cleaned_line:
                            context_steps.append(f"Authentication failures - verify service account permissions for `{container}` container")
                            context_steps.append(f"Check RBAC configuration in `{namespace}` namespace")
                        else:
                            context_steps.append(f"Analyze the repeated message pattern in `{container}` container")
                            context_steps.append(f"Determine if this behavior is expected or indicates a system problem")
                        
                        # Add severity-specific steps
                        if count >= 10:
                            severity = 1
                            context_steps.insert(0, f"CRITICAL: {count} identical messages - immediate investigation required")
                            context_steps.append(f"Consider restarting `{container}` container if issue persists")
                        elif count >= 5:
                            severity = 2
                            context_steps.insert(0, f"WARNING: {count} repeated messages detected")
                            context_steps.append(f"Monitor `{container}` container behavior and resource usage")
                        else:
                            context_steps.insert(0, f"INFO: {count} repeated messages - monitor for escalation")
                        
                        next_steps_str = "\n".join(context_steps[:5])  # Limit to 5 steps

                        # Create issue for this anomaly
                        issues_json["issues"].append({
                            "title": f"Application Log: Frequent Log Anomaly Detected in {container}",
                            "details": f"**Repeated Message:** {cleaned_line}\n**Occurrences:** {count}\n**Container:** {container}",
                            "next_steps": next_steps_str,
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
            # The 'details' field is now pre-formatted with grouped samples and context
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