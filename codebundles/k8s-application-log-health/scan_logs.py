#!/usr/bin/env python3

import os
import json
import re
from pathlib import Path
import sys
from collections import defaultdict
from difflib import SequenceMatcher

def cleanup_log_line_for_grouping(line):
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

def main():
    namespace = os.getenv("NAMESPACE")
    workload_type = os.getenv("WORKLOAD_TYPE")
    workload_name = os.getenv("WORKLOAD_NAME")
    output_dir = "./"
    error_json = os.getenv("ERROR_JSON", "error_patterns.json")
    categories_str = os.getenv("CATEGORIES", "GenericError,AppFailure")
    issue_file = os.getenv("ISSUE_FILE")
    categories_to_match = [c.strip() for c in categories_str.split(",") if c.strip()]

    for var_name in ["NAMESPACE", "WORKLOAD_TYPE", "WORKLOAD_NAME"]:
        if not os.getenv(var_name):
            print(f"ERROR: Environment variable {var_name} is not set.", file=sys.stderr)
            sys.exit(1)

    pods_json_path = Path(output_dir) / "application_logs_pods.json"
    error_json_path = Path(error_json)
    issues_output_path = Path(issue_file)

    # Read the pods JSON
    try:
        with open(pods_json_path, "r", encoding="utf-8") as f:
            pods_data = json.load(f)
    except Exception as e:
        print(f"ERROR reading pods JSON: {e}", file=sys.stderr)
        sys.exit(1)

    # Read the error patterns JSON
    try:
        with open(error_json_path, "r", encoding="utf-8") as f:
            error_data = json.load(f)
    except Exception as e:
        print(f"ERROR reading error JSON: {e}", file=sys.stderr)
        sys.exit(1)

    # Pattern aggregators - use more specific keys to avoid duplicates
    category_issues = defaultdict(list)
    all_next_steps = []
    max_severity = 5

    # Map of numeric severity to text label
    severity_label_map = {
        1: "Critical",
        2: "Major", 
        3: "Minor",
        4: "Informational",
    }

    pods = [pod["metadata"]["name"] for pod in pods_data]

    print(f"Scanning logs for {workload_type}/{workload_name} in namespace {namespace}...")

    for pod in pods:
        print(f"Processing Pod: {pod}")
        pod_obj = next((p for p in pods_data if p["metadata"]["name"] == pod), None)
        if not pod_obj:
            continue

        containers = [c["name"] for c in pod_obj["spec"]["containers"]]

        for container in containers:
            print(f"  Processing Container: {container}")

            log_file = Path(output_dir) / f"{workload_type}_{workload_name}_logs" / f"{pod}_{container}_logs.txt"
            if not log_file.is_file():
                print(f"  Warning: No log file found at {log_file}", file=sys.stderr)
                continue

            with open(log_file, "r", encoding="utf-8") as lf:
                log_content = lf.read()

            # Skip if log content is empty or only contains "errors": []
            if not log_content.strip() or re.match(r'^\s*"errors":\s*\[\s*\]\s*$', log_content.strip()):
                continue

            # Apply infrastructure filters to exclude normal operational logs
            infrastructure_filters = error_data.get("infrastructure_filters", [])
            should_exclude = False
            
            for infra_filter in infrastructure_filters:
                if infra_filter.get("exclude", False):
                    pattern = infra_filter.get("pattern", "")
                    if pattern and re.search(pattern, log_content, re.IGNORECASE):
                        print(f"  Skipping infrastructure log (filter: {infra_filter.get('name', 'unknown')})")
                        should_exclude = True
                        break
            
            if should_exclude:
                continue

            # Check each pattern
            for pattern_def in error_data.get("patterns", []):
                category = pattern_def.get("category", "")
                if category not in categories_to_match:
                    continue

                pattern = pattern_def.get("match", "")
                severity = int(pattern_def.get("severity", 0))
                next_steps = pattern_def.get("next_steps", "")

                matched_lines = []
                for line in log_content.splitlines():
                    # Skip empty lines and lines that look like empty error arrays
                    if not line.strip() or re.match(r'^\s*"errors":\s*\[\s*\]\s*$', line.strip()):
                        continue
                    
                    # Additional filtering for "errors":[] patterns in JSON
                    if re.search(r'"errors"\s*:\s*\[\s*\]', line.strip()):
                        continue
                    
                    if re.search(pattern, line, re.IGNORECASE):
                        # Get context around this line (5 lines before and after)
                        context_lines = get_context_around_line(log_content.splitlines(), line.strip())
                        matched_lines.append({
                            'line': line.strip(),
                            'context': context_lines
                        })

                if matched_lines:
                    # Group similar lines to avoid repetition
                    grouped_lines = group_similar_lines(matched_lines)
                    
                    # Create more specific pattern key to avoid duplicates - include pattern info
                    pattern_key = f"{category}:{pattern[:50]}:{severity}"
                    category_issues[pattern_key].append({
                        "pod": pod,
                        "container": container,
                        "pattern": pattern,
                        "category": category,
                        "severity": severity,
                        "next_steps": next_steps,
                        "grouped_lines": grouped_lines
                    })

                    # Handle next_steps
                    if isinstance(next_steps, str):
                        replaced_steps = _replace_placeholders(next_steps, workload_type, workload_name, namespace)
                        all_next_steps.append(replaced_steps)
                    elif isinstance(next_steps, list):
                        for step in next_steps:
                            replaced_steps = _replace_placeholders(step, workload_type, workload_name, namespace)
                            all_next_steps.append(replaced_steps)

                    if severity < max_severity:
                        max_severity = severity

    # Prepare final JSON output with grouped issues
    issues_json = {"issues": [], "summary": []}

    if category_issues:
        # Consolidate issues by actual error content to avoid duplicates
        consolidated_issues = {}
        
        for pattern_key, pattern_matches in category_issues.items():
            category = pattern_matches[0]["category"]
            pattern = pattern_matches[0]["pattern"]
            severity = min(match["severity"] for match in pattern_matches)
            
            # Create consolidated details
            details_parts = []
            total_occurrences = 0
            sample_lines = []
            all_context_lines = []  # Collect all context lines for deduplication

            # --- Start: Cross-container aggregation (not pod-level) ---
            all_lines_from_all_containers = []
            for match in pattern_matches:
                for group in match["grouped_lines"]:
                    for similar_line in group["similar"]:
                        line_with_meta = similar_line.copy()
                        line_with_meta['pod'] = match['pod']
                        line_with_meta['container'] = match['container']
                        all_lines_from_all_containers.append(line_with_meta)
            
            # Group these lines across all containers to collapse similar messages
            cross_container_groups = group_similar_lines(all_lines_from_all_containers)
            total_occurrences = sum(g['count'] for g in cross_container_groups)
            # --- End: Cross-container aggregation ---

            # Limit the number of groups shown in the report for conciseness
            max_groups_to_show = 5
            groups_to_show = cross_container_groups[:max_groups_to_show]

            # Build the summary of log groups
            for group in groups_to_show:
                sample_line = group["sample"]
                count = group["count"]
                
                # Group by container name instead of pod name for cleaner reporting
                containers_in_group = sorted(list(set([f"`{line['container']}`" for line in group['similar']])))
                
                details_parts.append(f"• **{count}x occurrences** in container(s): {', '.join(containers_in_group)}")
                details_parts.append(f"  Sample: `{sample_line}`")
                details_parts.append("") # Spacer
                
                sample_lines.append(sample_line)
                all_context_lines.extend(group.get("context", []))

            if len(cross_container_groups) > max_groups_to_show:
                details_parts.append(f"... and {len(cross_container_groups) - max_groups_to_show} more similar log groups.")
                details_parts.append("")
            
            # Add deduplicated context at the end
            if all_context_lines:
                # Remove duplicates from context while preserving order
                seen_context = set()
                unique_context = []
                for ctx_line in all_context_lines:
                    # Skip the highlighted target lines from deduplication
                    if ctx_line.startswith(">>> "):
                        unique_context.append(ctx_line)
                    elif ctx_line not in seen_context:
                        unique_context.append(ctx_line)
                        seen_context.add(ctx_line)
                
                # Limit context to reasonable size (max 15 unique context lines)
                if len(unique_context) > 15:
                    # Keep a representative sample of context
                    unique_context = unique_context[:15]
                    unique_context.append("    ... (additional context lines omitted)")
                
                if unique_context:
                    details_parts.append("Context (deduplicated):")
                    details_parts.extend(unique_context)

            # Analyze sample lines for service-specific insights
            service_insights = extract_service_insights(sample_lines)
            
            # Deduplicate next steps and add service-specific guidance
            unique_next_steps = list(set(all_next_steps))
            if service_insights:
                unique_next_steps.extend(service_insights)
            
            severity_label = severity_label_map.get(severity, f"Unknown({severity})")

            # Create a content-based key to consolidate similar issues
            # Use the first sample line as the key to group similar errors
            if sample_lines:
                # Create a more robust content key that considers the actual error message
                first_sample = sample_lines[0]
                # Extract the error message part for better grouping
                error_match = re.search(r'"error"\s*:\s*"([^"]+)"', first_sample)
                if error_match:
                    error_msg = error_match.group(1)
                    # Clean the error message for grouping
                    cleaned_error = cleanup_log_line_for_grouping(error_msg)
                    content_key = f"error:{cleaned_error[:100]}"
                else:
                    # Fallback to the original method
                    content_key = cleanup_log_line_for_grouping(first_sample)
            else:
                content_key = f"{category}:{pattern[:50]}"
            
            # Consolidate issues with the same content
            if content_key in consolidated_issues:
                # Merge with existing issue
                existing = consolidated_issues[content_key]
                existing["total_occurrences"] += total_occurrences
                existing["severity"] = min(existing["severity"], severity)
                existing["details_parts"].extend(details_parts)
                existing["sample_lines"].extend(sample_lines)
                existing["unique_next_steps"].extend(unique_next_steps)
                # Use the most descriptive category name
                if len(category) > len(existing["category"]):
                    existing["category"] = category
            else:
                # Create new consolidated issue
                consolidated_issues[content_key] = {
                    "category": category,
                    "severity": severity,
                    "total_occurrences": total_occurrences,
                    "details_parts": details_parts,
                    "sample_lines": sample_lines,
                    "unique_next_steps": unique_next_steps
                }

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
            
            # Create a more descriptive title based on the actual error content
            title = f"Error pattern detected in {workload_type} `{workload_name}` ({issue_data['total_occurrences']} occurrences)"
            
            # Try to extract more specific information for the title
            if sample_lines:
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
                        title = f"`{service_name}` service errors in {workload_type} `{workload_name}` - \"{error_snippet}...\" ({issue_data['total_occurrences']} occurrences)"
                    else:
                        # Extract error type for more specific title
                        if 'connection refused' in error_msg.lower():
                            error_snippet = error_msg[:40].strip()
                            title = f"Connection refused errors in {workload_type} `{workload_name}` - \"{error_snippet}...\" ({issue_data['total_occurrences']} occurrences)"
                        elif 'timeout' in error_msg.lower():
                            error_snippet = error_msg[:40].strip()
                            title = f"Timeout errors in {workload_type} `{workload_name}` - \"{error_snippet}...\" ({issue_data['total_occurrences']} occurrences)"
                        elif 'rpc error' in error_msg.lower():
                            error_snippet = error_msg[:40].strip()
                            title = f"RPC communication errors in {workload_type} `{workload_name}` - \"{error_snippet}...\" ({issue_data['total_occurrences']} occurrences)"
                        elif 'authentication' in error_msg.lower() or 'auth' in error_msg.lower():
                            error_snippet = error_msg[:40].strip()
                            title = f"Authentication errors in {workload_type} `{workload_name}` - \"{error_snippet}...\" ({issue_data['total_occurrences']} occurrences)"
                        elif 'permission' in error_msg.lower() or 'forbidden' in error_msg.lower():
                            error_snippet = error_msg[:40].strip()
                            title = f"Permission/authorization errors in {workload_type} `{workload_name}` - \"{error_snippet}...\" ({issue_data['total_occurrences']} occurrences)"
                        elif 'not found' in error_msg.lower() or '404' in error_msg:
                            error_snippet = error_msg[:40].strip()
                            title = f"Resource not found errors in {workload_type} `{workload_name}` - \"{error_snippet}...\" ({issue_data['total_occurrences']} occurrences)"
                        elif 'database' in error_msg.lower() or 'db' in error_msg.lower():
                            error_snippet = error_msg[:40].strip()
                            title = f"Database connection errors in {workload_type} `{workload_name}` - \"{error_snippet}...\" ({issue_data['total_occurrences']} occurrences)"
                        elif 'memory' in error_msg.lower() or 'out of memory' in error_msg.lower():
                            error_snippet = error_msg[:40].strip()
                            title = f"Memory/resource exhaustion in {workload_type} `{workload_name}` - \"{error_snippet}...\" ({issue_data['total_occurrences']} occurrences)"
                        else:
                            # Use first part of error message for context
                            error_preview = error_msg[:40].strip()
                            if error_preview:
                                title = f"Error pattern in {workload_type} `{workload_name}` - \"{error_preview}...\" ({issue_data['total_occurrences']} occurrences)"
                else:
                    # Fallback title with entity names in backticks
                    title = f"Error pattern detected in `{workload_name}` ({issue_data['total_occurrences']} occurrences)"
            else:
                # Fallback title with entity names in backticks
                title = f"Error pattern detected in `{workload_name}` ({issue_data['total_occurrences']} occurrences)"
            
            # Create properly formatted details string
            details_str = "\n\n".join(unique_details)

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

    else:
        # No patterns matched => no entries in 'issues'
        issues_json["summary"].append(
            f"No issues found in {workload_type} '{workload_name}' (namespace '{namespace}')."
        )

    with open(issues_output_path, "w", encoding="utf-8") as f:
        json.dump(issues_json, f, indent=2)

def extract_service_insights(sample_lines):
    """Extract service-specific insights from error messages to generate targeted next steps."""
    insights = []
    
    # Combine all sample lines for analysis
    combined_text = "\n".join(sample_lines)
    
    # Extract RPC service errors with more precise patterns
    rpc_services = set()
    rpc_patterns = [
        r'lookup\s+([a-zA-Z][a-zA-Z0-9\-\.]*service[a-zA-Z0-9\-\.]*)',  # DNS lookups to services
        r'([a-zA-Z][a-zA-Z0-9\-]*service)[:\s]',  # Service names with service suffix  
        r'could not (?:retrieve|get|fetch|connect to|add to) ([a-zA-Z][a-zA-Z0-9\-]{2,15}):',  # Action + simple service name
        r'failed to (?:retrieve|get|fetch|connect to|add to) ([a-zA-Z][a-zA-Z0-9\-]{2,15}):',  # Failed actions with simple service name
        r'unable to (?:connect|reach|access) ([a-zA-Z][a-zA-Z0-9\-]{2,15})',  # Connection issues with simple service name
        r'connection refused to ([a-zA-Z][a-zA-Z0-9\-]{2,15})',  # Direct connection refusal to simple service name
        r'([a-zA-Z][a-zA-Z0-9\-]*)\s*service(?:\s|$|:)',  # Generic service references
    ]
    
    for pattern in rpc_patterns:
        matches = re.findall(pattern, combined_text, re.IGNORECASE)
        for match in matches:
            if isinstance(match, tuple):
                # For tuple matches, take the last non-empty element (should be the service name)
                service_name = None
                for m in reversed(match):
                    if m and not m.isdigit() and len(m.strip()) > 2:
                        service_name = m.strip()
                        break
                
                if service_name:
                    # Clean up the service name and validate it's actually a service
                    clean_service = service_name.strip().strip('"').strip("'").strip()
                    if _is_valid_service_name(clean_service):
                        rpc_services.add(clean_service)
            else:
                # Single match - clean and validate
                clean_service = match.strip().strip('"').strip("'").strip()
                if _is_valid_service_name(clean_service):
                    rpc_services.add(clean_service)
    
    # Extract common service operation patterns - using more precise patterns
    service_operations = {}
    operation_patterns = [
        (r'could not retrieve ([a-zA-Z][a-zA-Z0-9\-]{2,15})', 'read operations'),
        (r'failed to add to ([a-zA-Z][a-zA-Z0-9\-]{2,15})', 'write operations'),  
        (r'failed to (?:save|create|update|delete) ([a-zA-Z][a-zA-Z0-9\-]{2,15})', 'CRUD operations'),
        (r'timeout.*?([a-zA-Z][a-zA-Z0-9\-]*service)', 'timeout issues'),
        (r'connection refused.*?([a-zA-Z][a-zA-Z0-9\-]{2,15})', 'connection issues'),
    ]
    
    for pattern, operation_type in operation_patterns:
        matches = re.findall(pattern, combined_text, re.IGNORECASE)
        for match in matches:
            service_name = match if isinstance(match, str) else match[0] if isinstance(match, tuple) else str(match)
            clean_service = service_name.strip().strip('"').strip("'")
            if _is_valid_service_name(clean_service):
                if clean_service not in service_operations:
                    service_operations[clean_service] = []
                service_operations[clean_service].append(operation_type)

    # Generate targeted next steps with backticks around entity names
    if rpc_services:
        # Clean up service names and remove noise
        clean_services = []
        for service in rpc_services:
            # Remove common kubernetes suffixes for cleaner display
            clean_service = re.sub(r'\.otel-demo\.svc\.cluster\.local.*$', '', service)
            clean_service = re.sub(r'\.svc\.cluster\.local.*$', '', clean_service)
            clean_service = clean_service.strip()
            
            if _is_valid_service_name(clean_service):
                clean_services.append(clean_service)
        
        if clean_services:
            # Limit to most relevant services and format nicely with backticks
            unique_services = list(set(clean_services))[:3]  # Limit to 3 services
            service_list = ', '.join([f"`{service}`" for service in unique_services])
            
            # Provide meaningful guidance without specific commands
            insights.append(f"Check if {service_list} service pods are running and healthy")
            insights.append(f"Review recent logs from {service_list} for error patterns")
            insights.append(f"Verify {service_list} service endpoints are properly configured")
    
    # Add specific operation-based guidance with backticks
    if service_operations:
        for service, operations in service_operations.items():
            clean_service = re.sub(r'\.otel-demo\.svc\.cluster\.local.*$', '', service)
            clean_service = re.sub(r'\.svc\.cluster\.local.*$', '', clean_service)
            clean_service = clean_service.strip()
            
            if 'read operations' in operations:
                insights.append(f"Check {clean_service} service health endpoints and response times") 
            if 'write operations' in operations:
                insights.append(f"Verify {clean_service} service has proper storage and write permissions")
            if 'timeout issues' in operations:
                insights.append(f"Review {clean_service} service resource usage and performance")
    
    # Extract specific error codes and provide guidance
    if 'code = Unavailable' in combined_text:
        insights.append("Verify all service endpoints are populated and target services are running")
    if 'code = DeadlineExceeded' in combined_text:
        insights.append("Check if pods are resource-constrained or experiencing high load")
    if 'connection refused' in combined_text.lower():
        insights.append("Verify service ports and network policies allow proper connectivity")
        
    # Extract port numbers for network troubleshooting with backticks
    ports = set(re.findall(r':(\d{4,5})', combined_text))
    if ports:
        port_list = ', '.join([f"`{port}`" for port in sorted(ports)[:3]])  # Limit to 3 ports
        insights.append(f"Test connectivity to ports {port_list} from affected pods")
    
    return insights[:6]  # Limit to 6 most relevant insights

def _is_valid_service_name(service_name):
    """Check if a string is likely a valid service name."""
    if not service_name or len(service_name) < 2 or len(service_name) > 25:
        return False
    
    # Exclude common non-service words and phrases (but not if they're part of valid service names)
    exclusions = [
        'retrieve', 'get', 'fetch', 'connect', 'add', 'connect to', 'add to',
        'desc', 'code', 'error', 'rpc', 'tcp', 'transport', 'dialing', 'lookup', 
        'while', 'dial', 'during', 'checkout', 'cart during', 'user cart',
        'user cart during', 'user cart during checkout'
    ]
    
    # Special case: exclude standalone "user" but allow "userservice"
    if service_name.lower() == 'user':
        return False
    
    # Check exact matches and partial matches for exclusions
    service_lower = service_name.lower()
    for exclusion in exclusions:
        if service_lower == exclusion or (exclusion in service_lower and not service_name.endswith('service')):
            return False
    
    # Service names should be simple identifiers or end with 'service'
    if (re.match(r'^[a-zA-Z][a-zA-Z0-9\-]*$', service_name) and 
        (service_name.endswith('service') or len(service_name) <= 15)):
        return True
    
    return False

def get_context_around_line(all_lines, target_line, context_size=5):
    """Get context lines around a target line, removing duplicates."""
    try:
        # Try exact match first
        target_index = all_lines.index(target_line)
    except ValueError:
        # If exact match fails, try to find a line that matches when stripped
        target_index = None
        for i, line in enumerate(all_lines):
            if line.strip() == target_line:
                target_index = i
                break
        
        if target_index is None:
            # If still not found, return just the line itself
            return [f">>> {target_line} <<<"]
    
    start_index = max(0, target_index - context_size)
    end_index = min(len(all_lines), target_index + context_size + 1)
    
    # Collect all context lines
    context_lines = []
    for i in range(start_index, end_index):
        if i == target_index:
            context_lines.append(f">>> {all_lines[i]} <<<")  # Highlight the matched line
        else:
            context_lines.append(f"    {all_lines[i]}")
    
    # Remove duplicate context lines while preserving order
    seen_context = set()
    unique_context = []
    for ctx_line in context_lines:
        # Skip the highlighted target line from deduplication
        if ctx_line.startswith(">>> "):
            unique_context.append(ctx_line)
        elif ctx_line not in seen_context:
            unique_context.append(ctx_line)
            seen_context.add(ctx_line)
    
    # Limit context to reasonable size (max 10 unique context lines + target line)
    if len(unique_context) > 11:
        # Keep the target line and a few context lines before and after
        target_line_index = None
        for i, line in enumerate(unique_context):
            if line.startswith(">>> "):
                target_line_index = i
                break
        
        if target_line_index is not None:
            # Keep 3 lines before and 3 lines after the target line
            start_keep = max(0, target_line_index - 3)
            end_keep = min(len(unique_context), target_line_index + 4)
            unique_context = unique_context[start_keep:end_keep]
    
    return unique_context

def group_similar_lines(lines, similarity_threshold=0.8):
    """Group similar log lines together to reduce repetition."""
    if not lines:
        return []
    
    groups = []
    used_indices = set()
    
    for i, line_data in enumerate(lines):
        if i in used_indices:
            continue
            
        # Extract the actual line content for similarity comparison
        if isinstance(line_data, dict):
            line_content = line_data['line']
        else:
            line_content = line_data
            
        # Start a new group with this line
        group = {"sample": line_content, "count": 1, "similar": [line_data], "context": []}
        used_indices.add(i)
        
        # Find similar lines
        for j, other_line_data in enumerate(lines):
            if j <= i or j in used_indices:
                continue
                
            # Extract the actual line content for similarity comparison
            if isinstance(other_line_data, dict):
                other_line_content = other_line_data['line']
            else:
                other_line_content = other_line_data
                
            # Clean lines before comparing to ignore timestamps, uuids, etc.
            cleaned_line1 = cleanup_log_line_for_grouping(line_content)
            cleaned_line2 = cleanup_log_line_for_grouping(other_line_content)
            
            # Calculate similarity
            similarity = SequenceMatcher(None, cleaned_line1, cleaned_line2).ratio()
            if similarity >= similarity_threshold:
                group["count"] += 1
                group["similar"].append(other_line_data)
                used_indices.add(j)
        
        # Collect context from all similar lines
        for similar_line_data in group["similar"]:
            if isinstance(similar_line_data, dict) and 'context' in similar_line_data:
                group["context"].extend(similar_line_data['context'])
        
        # Remove duplicates from context while preserving order
        seen_context = set()
        unique_context = []
        for ctx_line in group["context"]:
            if ctx_line not in seen_context:
                unique_context.append(ctx_line)
                seen_context.add(ctx_line)
        
        group["context"] = unique_context[:10]  # Limit context to 10 lines max per group
        
        groups.append(group)
    
    # Sort groups by count (most frequent first)
    groups.sort(key=lambda x: x["count"], reverse=True)
    return groups

def _replace_placeholders(text: str, workload_type: str, workload_name: str, namespace: str) -> str:
    """Helper to replace placeholders in a single step string."""
    text = text.replace("${WORKLOAD_TYPE}", workload_type)
    text = text.replace("${WORKLOAD_NAME}", f"`{workload_name}`")
    text = text.replace("${NAMESPACE}", f"`{namespace}`")
    return text

if __name__ == "__main__":
    main()
