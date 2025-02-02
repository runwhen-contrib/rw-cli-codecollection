import os
import sys
import json
import fnmatch
import requests
from robot.api import TestSuite
from tabulate import tabulate

# =================================================================================
# Configuration / Constants
# =================================================================================

EXPLAIN_URL = "https://papi.beta.runwhen.com/bow/raw?"
HEADERS = {"Content-Type": "application/json"}
PERSISTENT_FILE = "task_analysis.json"
REFERENCE_FILE = "reference_scores.json"

# =================================================================================
# JSON Loading / Saving
# =================================================================================

def load_json_file(filepath):
    if os.path.exists(filepath):
        with open(filepath, "r", encoding="utf-8") as f:
            try:
                return json.load(f)
            except json.JSONDecodeError:
                print(f"Warning: Could not parse JSON from {filepath}. Returning empty list.")
                return []
    return []

def save_json_file(filepath, data):
    with open(filepath, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=4)

def load_reference_scores():
    return load_json_file(REFERENCE_FILE)

def load_persistent_data():
    return load_json_file(PERSISTENT_FILE)

def save_persistent_data(data):
    save_json_file(PERSISTENT_FILE, data)

# =================================================================================
# Robot File Parsing
# =================================================================================

def find_robot_files(directory, pattern="*.robot"):
    """
    Recursively find .robot files matching the pattern in the given directory.
    """
    matches = []
    for root, _, filenames in os.walk(directory):
        for filename in fnmatch.filter(filenames, pattern):
            matches.append(os.path.join(root, filename))
    return matches

def parse_robot_file(filepath):
    """
    Parse a Robot file using robot.api.TestSuite to extract:
      - Settings: documentation, metadata, suite_setup
      - Imported user variables from suite init
      - Tasks: name, doc, tags, has_issue, issue_is_dynamic, has_add_pre_to_report, has_push_metric
    Returns a dict with:
      {
         "settings": {
             "documentation": str,
             "metadata": {...},
             "suite_setup_name": str or None
         },
         "tasks": [
             {
               "name": str,
               "doc": str,
               "tags": [str, ...],
               "imported_variables": {...},
               "has_issue": bool,
               "issue_is_dynamic": bool,
               "has_add_pre_to_report": bool,
               "has_push_metric": bool
             }, ...
         ]
      }
    """
    suite = TestSuite.from_file_system(filepath)

    # Gather settings info
    settings_info = {
        "documentation": suite.doc or "",        # Suite-level doc
        "metadata": suite.metadata or {},        # e.g. {"Author": "XYZ", "Supports": "Kubernetes", ...}
        "suite_setup_name": None
    }
    if suite.setup:
        settings_info["suite_setup_name"] = suite.setup.name  # e.g. "Suite Initialization"

    tasks = []
    imported_variables = {}

    # Identify user variables from Suite Initialization
    for keyword in suite.resource.keywords:
        if "Suite Initialization" in keyword.name:
            for statement in keyword.body:
                try:
                    if "RW.Core.Import User Variable" in statement.name:
                        var_name = statement.args[0]
                        imported_variables[var_name] = var_name
                except Exception:
                    continue

    # Collect tasks
    for test in suite.tests:
        has_issue = False
        issue_is_dynamic = False
        has_add_pre_to_report = False
        has_push_metric = False

        for step in test.body:
            step_name = getattr(step, "name", "")
            step_args = getattr(step, "args", [])

            # Check for RW.Core.Add Issue
            if "RW.Core.Add Issue" in step_name:
                has_issue = True
                # Check if dynamic
                if any("${" in arg for arg in step_args):
                    issue_is_dynamic = True

            # Check for RW.Core.Add Pre To Report
            if "RW.Core.Add Pre To Report" in step_name:
                has_add_pre_to_report = True

            # Check for RW.Core.Push Metric
            if "RW.Core.Push Metric" in step_name:
                has_push_metric = True

        tasks.append({
            "name": test.name.strip(),
            "doc": (test.doc or "").strip(),
            "tags": [tag.strip() for tag in test.tags],
            "imported_variables": imported_variables,
            "has_issue": has_issue,
            "issue_is_dynamic": issue_is_dynamic,
            "has_add_pre_to_report": has_add_pre_to_report,
            "has_push_metric": has_push_metric
        })

    return {
        "settings": settings_info,
        "tasks": tasks
    }

# =================================================================================
# LLM Querying
# =================================================================================

def query_openai(prompt):
    try:
        response = requests.post(EXPLAIN_URL, json={"prompt": prompt}, headers=HEADERS, timeout=30)
        if response.status_code == 200:
            return response.json().get("explanation", "Response unavailable")
        print(f"Warning: LLM API returned status code {response.status_code}")
    except requests.RequestException as e:
        print(f"Error calling LLM API: {e}")
    return "Response unavailable"

# =================================================================================
# Scoring Logic (Task-Level)
# =================================================================================

def match_reference_score(task_title, reference_data):
    """
    If task_title matches a known entry in reference_data, return (score, reasoning).
    Otherwise (None, None).
    """
    for ref in reference_data:
        if ref["task"].lower() == task_title.lower():
            return ref["score"], ref.get("reasoning", "")
    return None, None

def score_task_title(title, doc, tags, imported_variables, existing_data, reference_data):
    """
    Base LLM-based scoring for clarity/specificity of a task name.
    """
    # 1) Check if it exists in existing_data
    for entry in existing_data:
        if entry["task"] == title:
            return entry["score"], entry.get("reasoning", ""), entry.get("suggested_title", "")

    # 2) Check reference data
    ref_score, ref_reasoning = match_reference_score(title, reference_data)
    if ref_score is not None:
        return ref_score, ref_reasoning, "No suggestion required"

    # 3) If not found, call LLM
    where_variable = next((var for var in imported_variables if var in title), None)
    prompt = f"""
Given the task title: "{title}", documentation: "{doc}", tags: "{tags}", and imported user variables: "{imported_variables}", 
provide a score from 1 to 5 based on clarity, human readability, and specificity.

Compare it to the following reference examples: {json.dumps(reference_data)}.
A 1 is vague like 'Check EC2 Health'; a 5 is detailed like 'Check Overutilized EC2 Instances in AWS Region `${{AWS_REGION}}` in AWS Account `${{AWS_ACCOUNT_ID}}`'.

Ensure that tasks with both a 'What' (resource type) and a 'Where' (specific scope) score at least a 4.
Assume variables will be substituted at runtime, so do not penalize titles for placeholders like `${{VAR_NAME}}`.
If a task lacks a specific 'Where' variable, suggest the most relevant imported variable as a "Where" in the reasoning.

Return a JSON object with keys: "score", "reasoning", "suggested_title".
"""
    response_text = query_openai(prompt)
    if not response_text or response_text == "Response unavailable":
        return 1, "Unable to retrieve response from LLM.", f"Improve: {title}"

    try:
        response_json = json.loads(response_text)
        base_score = response_json.get("score", 1)
        reasoning = response_json.get("reasoning", "")
        suggested_title = response_json.get("suggested_title", f"Improve: {title}")

        # If no 'where' variable but LLM gave >3, reduce it
        if not where_variable and base_score > 3:
            suggested_where = next(iter(imported_variables.values()), "N/A")
            base_score = 3
            reasoning += f" The task lacks a specific 'Where' variable; consider using `{suggested_where}`."

        return base_score, reasoning, suggested_title

    except (ValueError, json.JSONDecodeError):
        return 1, "Unable to parse JSON from LLM response.", f"Improve: {title}"

def apply_runbook_issue_rules(base_score, base_reasoning, has_issue, issue_is_dynamic):
    """
    Adjust the base LLM-based score depending on whether
    a runbook task raises issues, and if they are dynamic.
    """
    score = base_score
    reasoning = base_reasoning

    if not has_issue:
        # Possibly collecting data or adding to a report; penalize by -1 if we assume runbook tasks should raise an Issue.
        score = max(score - 1, 1)
        reasoning += " [Runbook] No RW.Core.Add Issue found. Possibly data-only? -1 penalty.\n"
    else:
        # has_issue == True
        if issue_is_dynamic:
            # +1 for dynamic
            score = min(score + 1, 5)
            reasoning += " [Runbook] Issue is dynamic (has variables). +1 bonus.\n"
        else:
            reasoning += " [Runbook] Issue is static (no variables). No bonus.\n"

    return score, reasoning

# =================================================================================
# Codebundle-Level Checks
# =================================================================================

def compute_runbook_codebundle_score(num_tasks):
    """
    Return (score, reasoning) for the entire runbook codebundle
    based on the total number of tasks.
    """
    if num_tasks < 3:
        return 2, f"Only {num_tasks} tasks => under recommended minimum (3)."
    elif 3 <= num_tasks <= 6:
        return 3, f"{num_tasks} tasks => basic coverage."
    elif 7 <= num_tasks <= 8:
        return 4, f"{num_tasks} tasks => near ideal sweet spot (7-8)."
    elif 9 <= num_tasks <= 10:
        return 3, f"{num_tasks} tasks => slightly above recommended sweet spot."
    else:  # >10
        return 2, f"{num_tasks} tasks => likely too large for a single runbook."

# =================================================================================
# Lint Checks: CodeBundle Development Checklist
# =================================================================================

def lint_codebundle(settings_info, tasks, is_runbook, is_sli):
    """
    Checks the parsed "settings_info" and "tasks" data against the
    CodeBundle Development Checklist. Returns a dict:

      {
        "lint_score": int,  # 1..5
        "reasons": [str, str, ...]  # Explanation of any issues
      }
    """
    score = 5
    reasons = []

    # SETTINGS CHECKS
    doc = settings_info.get("documentation", "")
    if not doc.strip():
        score -= 1
        reasons.append("Missing or empty suite-level Documentation in *** Settings ***.")

    metadata = settings_info.get("metadata", {})
    # Check for required metadata keys
    for key in ["Author", "Display Name", "Supports"]:
        if key not in metadata:
            score -= 1
            reasons.append(f"Missing Metadata '{key}' in *** Settings ***.")

    # Suite Setup
    if not settings_info.get("suite_setup_name"):
        score -= 1
        reasons.append("No Suite Setup found (e.g. 'Suite Initialization').")

    # TASK CHECKS
    for t in tasks:
        if not t["doc"].strip():
            score -= 1
            reasons.append(f"Task '{t['name']}' has no [Documentation].")

        # For a runbook, ideally tasks that do something should either raise an issue or add to the report
        if is_runbook:
            if (not t["has_issue"]) and (not t["has_add_pre_to_report"]):
                # Could be purely data collection, but let's penalize it slightly
                # if it truly does nothing to "surface" results
                score -= 0.5
                reasons.append(f"Runbook task '{t['name']}' neither raises issues nor calls RW.Core.Add Pre To Report.")

        # For an SLI, ideally it should push at least one metric
        if is_sli:
            if not t["has_push_metric"]:
                score -= 1
                reasons.append(f"SLI task '{t['name']}' did not call RW.Core.Push Metric.")

    # Clamp score to [1..5]
    if score < 1:
        score = 1
    elif score > 5:
        score = 5

    return {
        "lint_score": score,
        "reasons": reasons
    }

# =================================================================================
# Main Analysis
# =================================================================================

def analyze_codebundles(directory):
    """
    1) Parse each .robot file (get settings + tasks).
    2) For each file, do:
       - Task-level LLM scoring
       - (if runbook) apply issue logic
       - (if runbook) compute codebundle-level score for # tasks
       - Lint check using the CodeBundle Development Checklist
    3) Persist combined results to PERSISTENT_FILE.
    4) Return (task_results, codebundle_results, lint_results).
    """
    robot_files = find_robot_files(directory, "*.robot")
    existing_data = load_persistent_data()
    reference_data = load_reference_scores()

    codebundle_map = {}  # (bundle_name, file_name) => { "settings": {...}, "tasks": [...] }

    # Parse each file
    for filepath in robot_files:
        bundle_name = os.path.basename(os.path.dirname(filepath))
        file_name = os.path.basename(filepath)

        parsed_data = parse_robot_file(filepath)
        codebundle_map[(bundle_name, file_name)] = parsed_data

    all_task_results = []
    codebundle_results = []
    lint_results = []

    for (bundle_name, file_name), parsed in codebundle_map.items():
        settings_info = parsed["settings"]
        tasks = parsed["tasks"]

        is_runbook = "runbook.robot" in file_name.lower()
        is_sli = "sli.robot" in file_name.lower()

        # ========== 1) Task-Level Scoring ==========
        for t in tasks:
            base_score, base_reasoning, suggested_title = score_task_title(
                title=t["name"],
                doc=t["doc"],
                tags=t["tags"],
                imported_variables=t["imported_variables"],
                existing_data=existing_data,
                reference_data=reference_data
            )

            final_score = base_score
            final_reasoning = base_reasoning

            # If runbook, apply "issue logic"
            if is_runbook:
                final_score, final_reasoning = apply_runbook_issue_rules(
                    final_score,
                    final_reasoning,
                    t["has_issue"],
                    t["issue_is_dynamic"]
                )

            all_task_results.append({
                "codebundle": bundle_name,
                "file": file_name,
                "task": t["name"],
                "score": final_score,
                "reasoning": final_reasoning,
                "suggested_title": suggested_title
            })

        # ========== 2) Codebundle-Level Scoring (Runbooks) ==========
        if is_runbook:
            num_tasks = len(tasks)
            cscore, creasoning = compute_runbook_codebundle_score(num_tasks)
            codebundle_results.append({
                "codebundle": bundle_name,
                "file": file_name,
                "num_tasks": num_tasks,
                "codebundle_score": cscore,
                "reasoning": creasoning
            })

        # ========== 3) Lint Checks ==========
        lint_result = lint_codebundle(settings_info, tasks, is_runbook, is_sli)
        lint_results.append({
            "codebundle": bundle_name,
            "file": file_name,
            "lint_score": lint_result["lint_score"],
            "reasons": lint_result["reasons"]
        })

    # Persist final combined data
    combined_data = {
        "task_results": all_task_results,
        "codebundle_results": codebundle_results,
        "lint_results": lint_results
    }
    save_persistent_data(combined_data)

    return all_task_results, codebundle_results, lint_results

# =================================================================================
# Reporting
# =================================================================================

def print_analysis_report(task_results, codebundle_results, lint_results):
    """
    Print:
      1) Task-Level Analysis
      2) Codebundle-Level Analysis (Runbooks)
      3) Codebundle Linting
    """
    # 1) Task-Level Table
    headers = ["Codebundle", "File", "Task", "Score"]
    table_data = []
    low_score_entries = []

    for entry in task_results:
        table_data.append([
            entry["codebundle"],
            entry["file"],
            entry["task"],
            f"{entry['score']}/5"
        ])
        if entry["score"] <= 3:
            low_score_entries.append(entry)

    print("\n=== Task-Level Analysis ===\n")
    print(tabulate(table_data, headers=headers, tablefmt="fancy_grid"))

    if low_score_entries:
        print("\n--- Detailed Explanations for Task Scores <= 3 ---\n")
        for entry in low_score_entries:
            print(f"• Codebundle: {entry['codebundle']}")
            print(f"  File: {entry['file']}")
            print(f"  Task: {entry['task']}")
            print(f"  Score: {entry['score']}/5")
            print(f"  Reasoning:\n    {entry['reasoning']}")
            print(f"  Suggested Title:\n    {entry['suggested_title']}")
            print("-" * 60)

    # 2) Codebundle-Level Analysis (Runbooks)
    if codebundle_results:
        headers_cb = ["Codebundle", "File", "Num Tasks", "Codebundle Score", "Reasoning"]
        table_data_cb = []
        for c in codebundle_results:
            table_data_cb.append([
                c["codebundle"],
                c["file"],
                str(c["num_tasks"]),
                f"{c['codebundle_score']}/5",
                c["reasoning"]
            ])

        print("\n=== Codebundle-Level Analysis (Runbooks) ===\n")
        print(tabulate(table_data_cb, headers=headers_cb, tablefmt="fancy_grid"))

    # 3) Lint Results
    if lint_results:
        headers_lint = ["Codebundle", "File", "Lint Score", "Reasons"]
        table_data_lint = []
        for lr in lint_results:
            # Combine the reasons with line breaks or bullet points
            reason_text = "\n".join([f"- {r}" for r in lr["reasons"]]) if lr["reasons"] else ""
            table_data_lint.append([
                lr["codebundle"],
                lr["file"],
                f"{lr['lint_score']}/5",
                reason_text
            ])

        print("\n=== Codebundle Linting ===\n")
        print(tabulate(table_data_lint, headers=headers_lint, tablefmt="fancy_grid"))

    print()

def main():
    # Default directory if none is provided
    codebundles_dir = "../../codebundles"

    # If an argument is passed from CLI, use that instead
    if len(sys.argv) > 1:
        codebundles_dir = sys.argv[1]

    # (Then run your analysis as before)
    task_results, codebundle_results, lint_results = analyze_codebundles(codebundles_dir)
    print_analysis_report(task_results, codebundle_results, lint_results)
    print(f"\nAnalysis complete for directory: {codebundles_dir}")

if __name__ == "__main__":
    main()
