#!/usr/bin/env python3

import sys
import json
import ast
import re

# If you can't install rapidfuzz, you could try fuzzywuzzy or skip approximate matching
try:
    from rapidfuzz import fuzz
except ImportError:
    # Fallback: define a trivial function that returns 100 if strings match exactly, else 0
    class FakeFuzz:
        @staticmethod
        def partial_ratio(a, b):
            return 100 if a == b else 0
    fuzz = FakeFuzz()

def try_parse_as_json(data):
    """
    Attempt to parse `data` as JSON.
    Return a dict if successful, otherwise None.
    """
    try:
        parsed = json.loads(data)
        if isinstance(parsed, dict):
            return parsed
        return None
    except (json.JSONDecodeError, TypeError):
        return None

def try_parse_as_python_literal(data):
    """
    Attempt to parse `data` as a Python dict literal using ast.literal_eval.
    Return a dict if successful, otherwise None.
    """
    try:
        parsed = ast.literal_eval(data)
        if isinstance(parsed, dict):
            return parsed
        return None
    except (ValueError, SyntaxError):
        return None

def decode_top_level(data):
    """
    Given the raw string `data`, try to parse it as either JSON or Python-literal dict.
    If it’s a dict, return that dict. Otherwise, return None.
    """
    data_stripped = data.strip()
    # If the entire thing is wrapped in quotes, remove them
    if len(data_stripped) >= 2:
        if ((data_stripped.startswith('"') and data_stripped.endswith('"')) or
            (data_stripped.startswith("'") and data_stripped.endswith("'"))):
            data_stripped = data_stripped[1:-1].strip()

    # Try parse as JSON
    as_json = try_parse_as_json(data_stripped)
    if as_json is not None:
        return as_json

    # Try parse as Python dict
    as_python = try_parse_as_python_literal(data_stripped)
    if as_python is not None:
        return as_python

    # Fallback
    return None

def remove_ephemeral_fields(line):
    """
    Remove ephemeral/timestamp-like data from the line using regexes:
    - Leading ISO8601 timestamps (e.g. 2025-02-09T09:36:35.255650Z)
    - bracketed times like [  3642.480217s]
    - IP:port patterns
    """
    # Remove leading ISO8601 timestamps
    # e.g. 2025-02-09T09:35:33.433770318Z ...
    line = re.sub(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]{8,}Z\s*", "", line)

    # Remove bracketed ephemeral times like [  3642.480217s]
    line = re.sub(r"\[\s*[0-9]+\.[0-9]+s\]", "[<time-s>]", line)

    # Remove IP:port patterns
    # e.g. 10.68.6.38:8086 => <IP>:<PORT>
    line = re.sub(r"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+", "<IP>:<PORT>", line)

    return line

def normalize_line(line):
    """
    Optionally remove ephemeral bits from each line.
    And do final .strip().
    """
    line = line.rstrip("\r")  # remove windows CR if needed
    line = remove_ephemeral_fields(line)
    # Possibly also remove or unify any trailing quotes or extra escaping
    line = line.strip()
    return line

def group_or_add_line(log_line_groups, new_line, threshold=80):
    """
    Attempt to place `new_line` into an existing log-line group if
    it's at least `threshold`% similar to that group's representative.
    Otherwise, add a new group.

    log_line_groups is a list of dicts like:
        [
          {
            "representative": "some line",
            "lines": [...],
            "count": <int>
          }
        ]

    Returns None, modifies log_line_groups in place.
    """
    for group in log_line_groups:
        rep = group["representative"]
        # We use partial_ratio or ratio; partial_ratio is more lenient
        score = fuzz.partial_ratio(rep, new_line)
        if score >= threshold:
            # we consider them the same "deduplicated" line
            group["count"] += 1
            group["lines"].append(new_line)
            return
    # if none matched, create a new group
    log_line_groups.append({
        "representative": new_line,
        "lines": [new_line],
        "count": 1
    })

def summarize_lines(multi_line_text, fuzzy_threshold=80):
    """
    Summarize a string containing multiple lines by:
      - splitting into lines
      - normalizing ephemeral data
      - fuzzy deduplicating (similar lines => single representative)

    Returns a dict with:
      {
        "total_lines": <int>,
        "unique_log_line_groups": <int>,
        "log_line_groups": <list_of_dicts>
      }
    """
    lines = multi_line_text.split("\n")
    total = 0
    log_line_groups = []

    for ln in lines:
        # Basic normalization
        norm = normalize_line(ln)
        # Optionally skip truly empty lines
        if not norm:
            continue

        total += 1
        # Try to group with fuzzy threshold
        group_or_add_line(log_line_groups, norm, threshold=fuzzy_threshold)

    # Build final structure
    groups_arr = []
    for g in log_line_groups:
        groups_arr.append({
            "representative": g["representative"],
            "count": g["count"],
            "examples": g["lines"][:3]  # maybe store up to 3 examples
        })

    summary = {
        "total_lines": total,
        "unique_log_line_groups": len(log_line_groups),
        "log_line_groups": groups_arr
    }
    return summary

def main():
    # 1) Read input from stdin or command line
    if len(sys.argv) > 1:
        raw_data = " ".join(sys.argv[1:])
    else:
        raw_data = sys.stdin.read()

    # 2) Parse as top-level dict
    parsed_dict = decode_top_level(raw_data)

    # 3) If top-level is a dict, handle each container key
    final_result = {"summary_by_container": {}}

    if parsed_dict is not None:
        # We expect each key to be a container name, each value is multiline logs
        for container_name, log_text in parsed_dict.items():
            if not isinstance(log_text, str):
                log_text = str(log_text)  # fallback
            summary = summarize_lines(log_text, fuzzy_threshold=85)
            final_result["summary_by_container"][container_name] = summary
    else:
        # Treat the entire raw_data as unknown logs
        summary = summarize_lines(raw_data, fuzzy_threshold=85)
        final_result["summary_by_container"]["unknown"] = summary

    # 4) Generate and print final reports
    report_md = build_markdown_report(final_result)
    report_cli = build_plain_text_report(final_result)
    
    # Print the plain-text version to stdout (more CLI-friendly)
    print(report_cli)

def build_plain_text_report(data):
    """
    Build and return a plain-text summary from `data`.
    `data` is expected to be the final_result dict with structure:
      {
        "summary_by_container": {
          <container_name>: {
            "total_lines": <int>,
            "unique_log_line_groups": <int>,
            "log_line_groups": [
              {
                "representative": <str>,
                "count": <int>,
                "examples": [<str>, ...]
              },
              ...
            ]
          }
        }
      }
    """
    lines = []
    lines.append("LOG SUMMARY")
    lines.append("========================\n")

    summary = data.get("summary_by_container", {})

    for container_name, details in summary.items():
        lines.append(f"Container: {container_name}")
        lines.append("-" * (len("Container: ") + len(container_name)))
        lines.append(f"  Total lines: {details['total_lines']}")
        lines.append(f"  Unique Log Line Groups: {details['unique_log_line_groups']}\n")

        # Log line groups
        for idx, group in enumerate(details.get("log_line_groups", []), start=1):
            lines.append(f"  Log Line Group {idx}:")
            lines.append(f"    Count: {group['count']}")
            rep_snippet = group['representative'][:500]
            lines.append("    Representative line:")
            lines.append(f"      {rep_snippet}")

            examples = group.get("examples", [])
            if examples:
                lines.append("    Examples:")
                for ex_idx, ex_line in enumerate(examples[:3], start=1):
                    ex_snippet = ex_line[:500]
                    lines.append(f"      {ex_idx}. {ex_snippet}")
            lines.append("")

        lines.append("")

    return "\n".join(lines)

def build_markdown_report(data):
    """
    Build and return a Markdown-formatted summary from `data`.
    """
    lines = []
    lines.append("# Error Log Summary Report\n")
    
    summary = data.get("summary_by_container", {})
    for container_name, details in summary.items():
        lines.append(f"## Container: `{container_name}`")
        lines.append(f"- **Total lines**: {details['total_lines']}")
        lines.append(f"- **Unique Log Line Groups**: {details['unique_log_line_groups']}\n")
        
        for idx, group in enumerate(details["log_line_groups"], start=1):
            rep = group["representative"]
            count = group["count"]
            examples = group.get("examples", [])
            
            lines.append(f"### Log Line Group {idx}")
            lines.append(f"- Count: {count}")
            lines.append(f"- **Representative line**:\n\n```text\n{rep[:500]}\n```\n")
            
            if examples:
                lines.append("**Examples**:")
                for ex_idx, ex_line in enumerate(examples[:2], start=1):
                    lines.append(f"  {ex_idx}. ```text\n{ex_line[:500]}\n```")
            lines.append("")
    return "\n".join(lines)

if __name__ == "__main__":
    main()
