import json
import re
import os

def main():
    with open("task_analysis.json", "r") as f:
        data = json.load(f)
    
    # data could be the full structure: { "task_results": [...], "codebundle_results": [...], ... }
    # for this example, focus on data["task_results"]
    task_results = data.get("task_results", [])

    for entry in task_results:
        old_title = entry["task"]
        new_title = entry["suggested_title"]
        file_path = entry["file"]  # e.g. "runbook.robot"
        
        # Skip if there's no new suggestion or if new == old
        if new_title.startswith("Improve:") or new_title == old_title:
            continue

        # Ensure the file exists
        if not os.path.exists(file_path):
            continue
        
        # Update lines in the .robot file
        with open(file_path, "r") as rf:
            lines = rf.readlines()
        
        updated_lines = []
        for line in lines:
            # Heuristic: find the line that includes old_title in a task definition
            # E.g. line: "Check Deployment Log For Issues with `${DEPLOYMENT_NAME}`"
            # You might refine to match Robot's exact syntax for tasks
            if old_title in line:
                # Replace only the first occurrence
                line = line.replace(old_title, new_title, 1)
            updated_lines.append(line)
        
        # Write the updated file
        with open(file_path, "w") as wf:
            wf.writelines(updated_lines)

if __name__ == "__main__":
    main()
