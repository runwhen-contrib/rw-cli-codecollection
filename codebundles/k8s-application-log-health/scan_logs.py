#!/usr/bin/env python3

import os
import json
import re
from pathlib import Path
import sys

def main():
    namespace = os.getenv("NAMESPACE")
    workload_type = os.getenv("WORKLOAD_TYPE")
    workload_name = os.getenv("WORKLOAD_NAME")
    output_dir = os.getenv("SHARED_TEMP_DIR")
    error_json = os.getenv("ERROR_JSON", "error_patterns.json")
    categories_str = os.getenv("CATEGORIES", "GenericError,AppFailure")
    issue_file = os.getenv("ISSUE_FILE")
    categories_to_match = [c.strip() for c in categories_str.split(",") if c.strip()]

    for var_name in ["NAMESPACE", "WORKLOAD_TYPE", "WORKLOAD_NAME", "OUTPUT_DIR"]:
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

    # Aggregators
    aggregator = {}
    all_next_steps = []
    max_severity = 0

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

            for pattern_def in error_data.get("patterns", []):
                category = pattern_def.get("category", "")
                if category not in categories_to_match:
                    continue

                pattern = pattern_def.get("match", "")
                severity = int(pattern_def.get("severity", 0))
                next_steps = pattern_def.get("next_steps", "")

                matched_lines = []
                for line in log_content.splitlines():
                    if re.search(pattern, line, re.IGNORECASE):
                        matched_lines.append(line)

                if matched_lines:
                    # Collect logs in aggregator
                    aggregator.setdefault(container, "")
                    aggregator[container] += (
                        f"\n--- Pod: {pod} (pattern: {pattern}) ---\n"
                        + "\n".join(matched_lines) + "\n"
                    )

                    # Handle next_steps if it is a list or a string
                    if isinstance(next_steps, str):
                        # Replace placeholders in the single string
                        replaced_steps = _replace_placeholders(next_steps, workload_type, workload_name, namespace)
                        all_next_steps.append(replaced_steps)
                    elif isinstance(next_steps, list):
                        # Replace placeholders in each item of the list
                        for step in next_steps:
                            replaced_steps = _replace_placeholders(step, workload_type, workload_name, namespace)
                            all_next_steps.append(replaced_steps)

                    if severity > max_severity:
                        max_severity = severity

    # Final JSON
    issues_json = {"issues": []}

    if aggregator:
        details_json = {}
        for container_name, matched_text in aggregator.items():
            details_json[container_name] = matched_text

        # Deduplicate next steps
        unique_next_steps = list(set(all_next_steps))

        categories_joined = ", ".join(categories_to_match)
        title = (f"Errors detected in {workload_type} `{workload_name}` "
                 f"(namespace `{namespace}`) - {categories_joined}")

        new_issue = {
            "title": title,
            "details": details_json,
            "next_steps": unique_next_steps,
            "severity": max_severity
        }
        issues_json["issues"].append(new_issue)

    with open(issues_output_path, "w", encoding="utf-8") as f:
        json.dump(issues_json, f, indent=2)

    print(f"Finished. Wrote single aggregated issue to {issues_output_path}")

def _replace_placeholders(text: str, workload_type: str, workload_name: str, namespace: str) -> str:
    """Helper to replace placeholders in a single step string."""
    text = text.replace("${WORKLOAD_TYPE}", workload_type)
    text = text.replace("${WORKLOAD_NAME}", f"`{workload_name}`")
    text = text.replace("${NAMESPACE}", f"`{namespace}`")
    return text

if __name__ == "__main__":
    main()
