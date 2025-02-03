import json
import os

def main():
    with open("task_analysis.json", "r") as f:
        data = json.load(f)

    task_results = data.get("task_results", [])

    for entry in task_results:
        old_title = entry["task"]         # existing task name
        new_title = entry.get("suggested_title")  # might be None if not present

        # If new_title is None or empty, skip
        if not new_title:
            continue

        # If new_title is a placeholder or the same as old_title, skip
        if new_title.startswith("Improve:") or new_title == old_title:
            continue

        file_path = entry["filepath"]
        if not os.path.exists(file_path):
            continue

        # Now do your file read/replace
        with open(file_path, "r") as rf:
            lines = rf.readlines()

        updated_lines = []
        for line in lines:
            # If old_title appears in the line that sets the task name, do a replacement
            if old_title in line:
                line = line.replace(old_title, new_title, 1)
            updated_lines.append(line)

        with open(file_path, "w") as wf:
            wf.writelines(updated_lines)

if __name__ == "__main__":
    main()
