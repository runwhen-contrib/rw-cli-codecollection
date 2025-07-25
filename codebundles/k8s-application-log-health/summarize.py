#!/usr/bin/env python3

import sys
import json
import re
from collections import defaultdict
from difflib import SequenceMatcher


def main():
    # 1) Read input
    if len(sys.argv) > 1:
        raw_data = " ".join(sys.argv[1:])
    else:
        raw_data = sys.stdin.read()

    # 2) Try to parse as JSON first (new format)
    try:
        parsed_data = json.loads(raw_data)
        if isinstance(parsed_data, dict) and "issues" in parsed_data:
            # New grouped format
            report = build_grouped_report(parsed_data)
            print(report)
            return
    except (json.JSONDecodeError, TypeError):
        pass

    # 3) Fall back to old parsing logic
    parsed_dict = decode_top_level(raw_data)
    final_result = {"summary_by_container": {}}

    if parsed_dict is not None:
        # We expect each key: container name => multiline logs
        for container_name, log_text in parsed_dict.items():
            if not isinstance(log_text, str):
                log_text = str(log_text)
            summary = summarize_lines(log_text, fuzzy_threshold=85)
            final_result["summary_by_container"][container_name] = summary
    else:
        # Treat the entire raw_data as unknown logs
        summary = summarize_lines(raw_data, fuzzy_threshold=85)
        final_result["summary_by_container"]["unknown"] = summary

    # 4) Output final reports
    report_cli = build_plain_text_report(final_result)
    print(report_cli)


def build_grouped_report(data):
    """Build a report from the new grouped issue format."""
    issues = data.get("issues", [])
    summary = data.get("summary", [])
    
    if not issues:
        return "✅ No log issues detected.\n" + "\n".join(summary)
    
    report_parts = []
    report_parts.append("📋 **Log Analysis Summary**")
    report_parts.append("=" * 50)
    
    # Add summary information
    if summary:
        report_parts.extend(summary)
        report_parts.append("")
    
    # Group issues by severity and category
    critical_issues = [i for i in issues if i.get("severity", 5) <= 2]
    warning_issues = [i for i in issues if i.get("severity", 5) == 3]
    info_issues = [i for i in issues if i.get("severity", 5) >= 4]
    
    if critical_issues:
        report_parts.append("🚨 **Critical Issues**")
        report_parts.append("-" * 30)
        for issue in critical_issues:
            report_parts.append(format_issue_summary(issue))
        report_parts.append("")
    
    if warning_issues:
        report_parts.append("⚠️  **Warning Issues**")
        report_parts.append("-" * 30)
        for issue in warning_issues:
            report_parts.append(format_issue_summary(issue))
        report_parts.append("")
    
    if info_issues:
        report_parts.append("ℹ️  **Informational Issues**")
        report_parts.append("-" * 30)
        for issue in info_issues:
            report_parts.append(format_issue_summary(issue))
        report_parts.append("")
    
    return "\n".join(report_parts)


def format_issue_summary(issue):
    """Formats a single issue into a human-readable summary, extracting key info from details."""
    title = issue.get('title', 'Unknown Issue')
    severity = issue.get('severity_label', 'Unknown')
    category = issue.get('category', 'N/A')
    occurrences = issue.get('occurrences', 'N/A')
    
    summary_parts = [
        f"**Issue: {title}**",
        f"  • Severity: {severity} | Category: {category} | Occurrences: {occurrences}"
    ]
    
    # The 'details' field contains pre-formatted log groups
    details_text = issue.get('details', '')
    
    # Extract the top 3-4 log groups from the details to keep the summary concise
    log_groups = details_text.split('... and ')[0] # Get text before the "... and more"
    log_group_lines = log_groups.strip().split('\n')
    
    # Limit to a reasonable number of lines for the summary
    max_lines_in_summary = 15
    if len(log_group_lines) > max_lines_in_summary:
        log_group_lines = log_group_lines[:max_lines_in_summary]
        log_group_lines.append("    ... (details truncated for summary)")

    if log_group_lines:
        summary_parts.append("  • **Sample Log Groups:**")
        summary_parts.extend([f"    {line}" for line in log_group_lines])

    return "\n".join(summary_parts)


def extract_pod_info(details_text):
    """Extract pod information and occurrence counts from details text."""
    pod_counts = defaultdict(int)
    
    # Look for patterns like "Pod: podname (container) - 5x occurrences"
    pod_pattern = r'Pod:\s+(\S+)\s+\([^)]+\)(?:\s+-\s+(\d+)x\s+occurrences)?'
    matches = re.findall(pod_pattern, details_text)
    
    for pod_name, count_str in matches:
        count = int(count_str) if count_str else 1
        pod_counts[pod_name] += count
    
    return dict(pod_counts)


def extract_sample_line(details_text):
    """Extract a sample log line from the details."""
    lines = details_text.split('\n')
    
    # Look for lines that don't start with "Pod:" - these are likely log content
    for line in lines:
        line = line.strip()
        if line and not line.startswith("Pod:") and not line.startswith("**") and not line.startswith("Context"):
            # Return the complete line without truncation
            return line
    
    return None

def extract_context_sample(details_text):
    """Extract a sample of context lines from the details."""
    lines = details_text.split('\n')
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
        return context_lines[:8]  # Show up to 8 context lines
    return []


def decode_top_level(text):
    """Try to decode the top-level structure (old format)."""
    text = text.strip()
    if not text:
        return None

    # Try JSON first
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass

    # Try to parse as a dict-like string
    if text.startswith("{") and text.endswith("}"):
        try:
            # Simple eval for dict-like strings (not secure but works for logs)
            return eval(text)
        except:
            pass

    return None


def summarize_lines(log_text, fuzzy_threshold=85):
    """Summarize log lines by grouping similar ones (old format)."""
    if not log_text or not log_text.strip():
        return {"total_lines": 0, "unique_patterns": [], "summary": "No log content"}

    lines = [line.strip() for line in log_text.split('\n') if line.strip()]
    
    if not lines:
        return {"total_lines": 0, "unique_patterns": [], "summary": "No meaningful log content"}

    # Group similar lines
    grouped = group_similar_log_lines(lines, fuzzy_threshold / 100.0)
    
    # Create summary
    total_lines = len(lines)
    unique_patterns = len(grouped)
    
    pattern_summaries = []
    for group in grouped[:5]:  # Show top 5 patterns
        sample = group["sample"]
            count = group["count"]
        if len(sample) > 80:
            sample = sample[:77] + "..."
        pattern_summaries.append(f"{count}x: {sample}")
    
    summary_text = f"Found {unique_patterns} distinct patterns in {total_lines} log lines"
    if len(grouped) > 5:
        summary_text += f" (showing top 5)"
    
    return {
        "total_lines": total_lines,
        "unique_patterns": unique_patterns,
        "pattern_summaries": pattern_summaries,
        "summary": summary_text
    }


def group_similar_log_lines(lines, similarity_threshold=0.8):
    """Group similar log lines together."""
    if not lines:
        return []
    
    groups = []
    used_indices = set()
    
    for i, line in enumerate(lines):
        if i in used_indices:
            continue
            
        # Start a new group with this line
        group = {"sample": line, "count": 1, "similar": [line]}
        used_indices.add(i)
        
        # Find similar lines
        for j, other_line in enumerate(lines):
            if j <= i or j in used_indices:
                continue
                
            # Calculate similarity
            similarity = SequenceMatcher(None, line, other_line).ratio()
            if similarity >= similarity_threshold:
                group["count"] += 1
                group["similar"].append(other_line)
                used_indices.add(j)
        
        groups.append(group)
    
    # Sort groups by count (most frequent first)
    groups.sort(key=lambda x: x["count"], reverse=True)
    return groups


def build_plain_text_report(final_result):
    """Build plain text report from old format."""
    report_lines = []
    report_lines.append("📋 Log Analysis Summary")
    report_lines.append("=" * 40)
    
    containers = final_result.get("summary_by_container", {})
    
    if not containers:
        return "No log data processed."
    
    for container_name, summary in containers.items():
        report_lines.append(f"\n**Container: {container_name}**")
        report_lines.append(f"  {summary.get('summary', 'No summary available')}")
        
        patterns = summary.get("pattern_summaries", [])
        if patterns:
            report_lines.append("  Top patterns:")
            for pattern in patterns:
                report_lines.append(f"    • {pattern}")
    
    return "\n".join(report_lines)


if __name__ == "__main__":
    main()
