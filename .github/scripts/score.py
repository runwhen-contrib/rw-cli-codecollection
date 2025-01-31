import os
import json
import fnmatch
import re
import requests
from robot.api import TestSuite

EXPLAIN_URL = "https://papi.beta.runwhen.com/bow/raw?"
HEADERS = {"Content-Type": "application/json"}
PERSISTENT_FILE = "task_analysis.json"

def find_robot_files(directory, pattern):
    """Find all robot files matching the pattern in the given directory."""
    matches = []
    for root, _, filenames in os.walk(directory):
        for filename in fnmatch.filter(filenames, pattern):
            matches.append(os.path.join(root, filename))
    return matches

def parse_robot_file(fpath):
    """Parse a Robot Framework file and extract task names."""
    suite = TestSuite.from_file_system(fpath)
    tasks = []
    for task in suite.tests:
        tasks.append(task.name.title())  # Ensure capitalization
    return tasks

def load_persistent_data():
    """Load previously stored analysis data to avoid redundant API calls."""
    if os.path.exists(PERSISTENT_FILE):
        with open(PERSISTENT_FILE, "r") as f:
            return json.load(f)
    return []

def save_persistent_data(data):
    """Save analysis data to persist results across runs."""
    with open(PERSISTENT_FILE, "w") as f:
        json.dump(data, f, indent=4)

def query_openai(prompt):
    """Query OpenAI API to get explanations or scoring."""
    response = requests.post(EXPLAIN_URL, json={"prompt": prompt}, headers=HEADERS)
    if response.status_code == 200:
        return response.json().get("explanation", "Response unavailable")
    return "Response unavailable"

def score_task_title(title, existing_data):
    """Use OpenAI API to score task titles based on specificity and readability, avoiding redundant API calls."""
    for entry in existing_data:
        if entry["task"] == title:
            return entry["score"]
    prompt = f"""
    Given the task title: "{title}", provide a score from 1 to 5 based on clarity, human readability, and specificity. 
    A 1 is vague like 'Check EC2 Health', a 5 is detailed like 'Check Overutilized EC2 Instances in AWS Region `\${{AWS_REGION}}` in AWS Account `\${{AWS_ACCOUNT_ID}}`'. 
    Ensure that tasks with both a 'What' (resource type) and a 'Where' (specific scope) score at least a 4. 
    Return only the score as a number.
    """
    score_text = query_openai(prompt)
    try:
        return int(score_text.strip())
    except ValueError:
        return 1

def suggest_improved_title(title, score, existing_data):
    """Use OpenAI API to suggest an improved task title if necessary, avoiding redundant API calls."""
    if score >= 4:
        return None  # No suggestion needed for high-scoring titles
    for entry in existing_data:
        if entry["task"] == title and entry["suggested_title"]:
            return entry["suggested_title"]
    prompt = f"""
    Given the task title: "{title}", suggest a more detailed version that includes 'What' and 'Where' information 
    such as specific placeholders like `\${{AWS_REGION}}` or `\${{AWS_ACCOUNT_ID}}`. 
    Avoid adding redundant information already present in the title.
    Ensure the title remains concise and meaningful.
    """
    return query_openai(prompt)

def analyze_codebundles(directory):
    """Analyze all codebundles and score task titles, leveraging persistence."""
    robot_files = find_robot_files(directory, '*.robot')
    existing_data = load_persistent_data()
    results = []
    
    for file in robot_files:
        if 'sli.robot' in file or 'runbook.robot' in file:
            tasks = parse_robot_file(file)
            for task in tasks:
                score = score_task_title(task, existing_data)
                suggestion = suggest_improved_title(task, score, existing_data)
                results.append({
                    "file": file,
                    "task": task,
                    "score": score,
                    "suggested_title": suggestion
                })
    
    save_persistent_data(results)
    return results

def print_analysis_report(results):
    """Prints a formatted analysis report."""
    print("\nTask Analysis Report:\n")
    for entry in results:
        print(f"File: {entry['file']}")
        print(f"  Task: {entry['task']}")
        print(f"  Score: {entry['score']}/5")
        if entry["suggested_title"]:
            print(f"  Suggested Title: {entry['suggested_title']}")
        print("-" * 60)

def main():
    """Main execution function."""
    codebundles_dir = "./codebundles"  # Adjust as needed
    analysis_results = analyze_codebundles(codebundles_dir)
    print_analysis_report(analysis_results)
    print("\nAnalysis complete. Results saved to task_analysis.json\n")

if __name__ == "__main__":
    main()
