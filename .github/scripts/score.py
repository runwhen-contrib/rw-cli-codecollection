import os
import json
import fnmatch
import re
import requests
from robot.api import TestSuite

EXPLAIN_URL = "https://papi.beta.runwhen.com/bow/raw?"
HEADERS = {"Content-Type": "application/json"}
PERSISTENT_FILE = "task_analysis.json"
REFERENCE_FILE = "reference_scores.json"

def load_reference_scores():
    if os.path.exists(REFERENCE_FILE):
        with open(REFERENCE_FILE, "r") as f:
            return json.load(f)
    return []

def find_robot_files(directory, pattern):
    """Find all robot files matching the pattern in the given directory."""
    matches = []
    for root, _, filenames in os.walk(directory):
        for filename in fnmatch.filter(filenames, pattern):
            matches.append(os.path.join(root, filename))
    return matches

def parse_robot_file(fpath):
    """Parse a Robot Framework file and extract task names, docs, tags, and imported variables."""
    suite = TestSuite.from_file_system(fpath)
    tasks = []
    variables = {var.name: var.value for var in suite.resource.variables}
    imported_variables = {}
    
    for keyword in suite.resource.keywords:
        if "Suite Initialization" in keyword.name.lower():
            for statement in keyword.body:
                if "RW.Core.Import User Variable" in statement.name:
                    var_name = statement.args[0]
                    imported_variables[var_name] = var_name  
    
    for task in suite.tests:
        tasks.append({
            "name": task.name.strip(),  
            "doc": task.doc.strip() if task.doc else "",  
            "tags": [tag.strip() for tag in task.tags],  
            "variables": variables,  
            "imported_variables": imported_variables  
        })
    return tasks

def load_persistent_data():
    if os.path.exists(PERSISTENT_FILE):
        with open(PERSISTENT_FILE, "r") as f:
            return json.load(f)
    return []

def save_persistent_data(data):
    with open(PERSISTENT_FILE, "w") as f:
        json.dump(data, f, indent=4)

def query_openai(prompt):
    response = requests.post(EXPLAIN_URL, json={"prompt": prompt}, headers=HEADERS)
    if response.status_code == 200:
        return response.json().get("explanation", "Response unavailable")
    return "Response unavailable"

def match_reference_score(title, reference_data):
    for ref in reference_data:
        if ref["task"].lower() == title.lower():
            return ref["score"], ref.get("reasoning", "")
    return None, None

def score_task_title(title, doc, tags, variables, imported_variables, existing_data, reference_data):
    for entry in existing_data:
        if entry["task"] == title:
            return entry["score"], entry.get("reasoning", "")
    
    ref_score, ref_reasoning = match_reference_score(title, reference_data)
    if ref_score is not None:
        return ref_score, ref_reasoning
    
    where_variable = next((var for var in imported_variables if var in title), None)
    
    prompt = r"""
    Given the task title: "{title}", documentation: "{doc}", tags: "{tags}", variables: "{variables}", and imported user variables: "{imported_variables}", provide a score from 1 to 5 based on clarity, human readability, and specificity.
    Compare it to the following reference examples: {reference_data}.
    A 1 is vague like 'Check EC2 Health', a 5 is detailed like 'Check Overutilized EC2 Instances in AWS Region `${{AWS_REGION}}` in AWS Account `${{AWS_ACCOUNT_ID}}`'. 
    Ensure that tasks with both a 'What' (resource type) and a 'Where' (specific scope) score at least a 4.
    Assume that variables will be substituted at runtime, so do not penalize titles for using placeholders like `${{VAR_NAME}}`.
    If a task lacks a specific 'Where' variable, suggest the most relevant imported variable as a "Where" in the reasoning and suggested improvement.
    Return the score and a short reasoning as a JSON object with keys "score" and "reasoning".
    """.format(title=title, doc=doc, tags=tags, variables=variables, imported_variables=imported_variables, reference_data=json.dumps(reference_data))
    
    response = query_openai(prompt)
    try:
        response_json = json.loads(response)
        score = response_json.get("score", 1)
        reasoning = response_json.get("reasoning", "")
        if not where_variable and score > 3:
            suggested_where = next(iter(imported_variables.values()), "N/A")
            score = 3  # Cap the score if no 'Where' variable exists
            reasoning += f" The task lacks a specific 'Where' variable, suggesting `{suggested_where}` as a possible location."
        return score, reasoning
    except (ValueError, json.JSONDecodeError):
        return 1, "Unable to parse response."

def analyze_codebundles(directory):
    robot_files = find_robot_files(directory, '*.robot')
    existing_data = load_persistent_data()
    reference_data = load_reference_scores()
    results = []
    
    for file in robot_files:
        if 'sli.robot' in file or 'runbook.robot' in file:
            tasks = parse_robot_file(file)
            for task in tasks:
                score, reasoning = score_task_title(
                    task["name"], task["doc"], task["tags"], task["variables"], task["imported_variables"], existing_data, reference_data
                )
                results.append({
                    "file": file,
                    "task": task["name"],
                    "score": score,
                    "reasoning": reasoning
                })
    
    save_persistent_data(results)
    return results

def print_analysis_report(results):
    print("\nTask Analysis Report:\n")
    for entry in results:
        print(f"File: {entry['file']}")
        print(f"  Task: {entry['task']}")
        print(f"  Score: {entry['score']}/5")
        print(f"  Reasoning: {entry['reasoning']}")
        print("-" * 60)

def main():
    codebundles_dir = "../../test"  
    analysis_results = analyze_codebundles(codebundles_dir)
    print_analysis_report(analysis_results)
    print("\nAnalysis complete. Results saved to task_analysis.json\n")

if __name__ == "__main__":
    main()
