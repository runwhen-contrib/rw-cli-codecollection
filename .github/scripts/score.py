import os
import json
import fnmatch
import requests
from robot.api import TestSuite
from tabulate import tabulate  # for pretty table output

EXPLAIN_URL = "https://papi.beta.runwhen.com/bow/raw?"
HEADERS = {"Content-Type": "application/json"}
PERSISTENT_FILE = "task_analysis.json"
REFERENCE_FILE = "reference_scores.json"


# --------------------------------------------
# Data Loading / Saving
# --------------------------------------------

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


# --------------------------------------------
# Robot File Parsing
# --------------------------------------------

def find_robot_files(directory, pattern="*.robot"):
    matches = []
    for root, _, filenames in os.walk(directory):
        for filename in fnmatch.filter(filenames, pattern):
            matches.append(os.path.join(root, filename))
    return matches

def parse_robot_file(filepath):
    suite = TestSuite.from_file_system(filepath)

    tasks = []
    imported_variables = {}

    for keyword in suite.resource.keywords:
        if "Suite Initialization" in keyword.name:
            for statement in keyword.body:
                try:
                    if "RW.Core.Import User Variable" in statement.name:
                        var_name = statement.args[0]
                        imported_variables[var_name] = var_name
                except Exception:
                    continue

    for task in suite.tests:
        tasks.append({
            "name": task.name.strip(),
            "doc": (task.doc or "").strip(),
            "tags": [tag.strip() for tag in task.tags],
            "imported_variables": imported_variables
        })

    return tasks


# --------------------------------------------
# LLM Querying
# --------------------------------------------

def query_openai(prompt):
    try:
        response = requests.post(EXPLAIN_URL, json={"prompt": prompt}, headers=HEADERS, timeout=30)
        if response.status_code == 200:
            return response.json().get("explanation", "Response unavailable")
        print(f"Warning: LLM API returned status code {response.status_code}")
    except requests.RequestException as e:
        print(f"Error calling LLM API: {e}")
    return "Response unavailable"


# --------------------------------------------
# Scoring Logic
# --------------------------------------------

def match_reference_score(task_title, reference_data):
    for ref in reference_data:
        if ref["task"].lower() == task_title.lower():
            return ref["score"], ref.get("reasoning", "")
    return None, None

def score_task_title(title, doc, tags, imported_variables, existing_data, reference_data):
    # 1. Check existing data for a match
    for entry in existing_data:
        if entry["task"] == title:
            return (
                entry["score"],
                entry.get("reasoning", ""),
                entry.get("suggested_title", "")
            )

    # 2. Check reference data
    ref_score, ref_reasoning = match_reference_score(title, reference_data)
    if ref_score is not None:
        return ref_score, ref_reasoning, "No suggestion required"

    # 3. Query the LLM
    where_variable = next((var for var in imported_variables if var in title), None)
    prompt = f"""
Given the task title: "{title}", documentation: "{doc}", tags: "{tags}", and imported user variables: "{imported_variables}", 
provide a score from 1 to 5 based on clarity, human readability, and specificity.

Compare it to the following reference examples: {json.dumps(reference_data)}.
A 1 is vague like 'Check EC2 Health'; a 5 is detailed like 'Check Overutilized EC2 Instances in AWS Region `${{AWS_REGION}}` in AWS Account `${{AWS_ACCOUNT_ID}}`'.

Ensure that tasks with both a 'What' (resource type) and a 'Where' (specific scope) score at least a 4.
Assume variables will be substituted at runtime, so do not penalize titles for placeholders like `${{VAR_NAME}}`.
If a task lacks a specific 'Where' variable, suggest the most relevant imported variable as a "Where" in the reasoning.

Return the score, reasoning, and a suggested improved title as a JSON object with keys: "score", "reasoning", "suggested_title".
"""

    response_text = query_openai(prompt)
    if not response_text or response_text == "Response unavailable":
        return 1, "Unable to retrieve response from LLM.", f"Improve {title}"

    try:
        response_json = json.loads(response_text)
        score = response_json.get("score", 1)
        reasoning = response_json.get("reasoning", "")
        suggested_title = response_json.get("suggested_title", f"Improve: {title}")

        if not where_variable and score > 3:
            suggested_where = next(iter(imported_variables.values()), "N/A")
            score = 3
            reasoning += f" The task lacks a specific 'Where' variable; consider using `{suggested_where}`."

        return score, reasoning, suggested_title

    except (ValueError, json.JSONDecodeError):
        return 1, "Unable to parse JSON from LLM response.", f"Improve: {title}"


# --------------------------------------------
# Main Analysis Flow
# --------------------------------------------

def analyze_codebundles(directory):
    robot_files = find_robot_files(directory, '*.robot')
    existing_data = load_persistent_data()
    reference_data = load_reference_scores()

    results = []

    for filepath in robot_files:
        # For demonstration, we'll define "codebundle" as the immediate parent folder
        # of the .robot file. You can adjust this logic as needed.
        #
        # e.g., if filepath is "/home/user/foo/codebundle1/mytest.robot"
        # bundle_name = "codebundle1", file_name = "mytest.robot"
        bundle_name = os.path.basename(os.path.dirname(filepath))
        file_name = os.path.basename(filepath)

        # Example filtering logic (optional)
        if "sli.robot" in file_name or "runbook.robot" in file_name:
            tasks = parse_robot_file(filepath)
            for task in tasks:
                score, reasoning, suggested_title = score_task_title(
                    task["name"],
                    task["doc"],
                    task["tags"],
                    task["imported_variables"],
                    existing_data,
                    reference_data
                )
                results.append({
                    "codebundle": bundle_name,
                    "file": file_name,
                    "task": task["name"],
                    "score": score,
                    "reasoning": reasoning,
                    "suggested_title": suggested_title
                })

    save_persistent_data(results)
    return results

def print_analysis_report(results):
    """
    Print a table of:
      - Codebundle
      - File
      - Task Title
      - Score
    
    Then, for any entry with a score <= 3, print the reasoning
    and suggested title as extra detail below the table.
    """
    # Prepare data for the concise table
    headers = ["Codebundle", "File", "Task", "Score"]
    table_data = []
    low_score_entries = []  # We'll collect entries with score <= 3 for later

    for entry in results:
        codebundle = entry.get("codebundle", "")
        file_name = entry.get("file", "")
        task = entry.get("task", "")
        score = entry.get("score", 0)
        
        # Add to main table rows
        table_data.append([
            codebundle,
            file_name,
            task,
            f"{score}/5"
        ])

        # If score <= 3, record for extended details
        if score <= 3:
            low_score_entries.append(entry)

    # Print the main table
    print("\n=== Task Analysis Report ===\n")
    print(tabulate(table_data, headers=headers, tablefmt="fancy_grid"))
    
    # Print extended reasoning and suggested title for lower-scored tasks
    if low_score_entries:
        print("\n--- Detailed Explanations for Scores <= 3 ---\n")
        for entry in low_score_entries:
            print(f"• Codebundle: {entry.get('codebundle', '')}")
            print(f"  File: {entry.get('file', '')}")
            print(f"  Task: {entry.get('task', '')}")
            print(f"  Score: {entry.get('score', '')}/5")
            print(f"  Reasoning: {entry.get('reasoning', '')}")
            print(f"  Suggested Title: {entry.get('suggested_title', '')}")
            print("-" * 60)

    print()  # Extra spacing at the end


def main():
    codebundles_dir = "../../test"
    analysis_results = analyze_codebundles(codebundles_dir)
    print_analysis_report(analysis_results)
    print(f"\nAnalysis complete. Results saved to {PERSISTENT_FILE}\n")

if __name__ == "__main__":
    main()
