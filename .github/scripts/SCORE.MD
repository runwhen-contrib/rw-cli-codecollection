> Note: This is moving to a github action at 

# CodeBundle Lint & Scoring Script

This script provides **automated linting and scoring** for Robot Framework-based RunWhen “CodeBundles.” It performs:

1. **Task-Level Scoring**  
   - Uses an LLM (OpenAI-like endpoint) to evaluate clarity of task titles.  
   - Applies runbook logic to see if tasks raise issues (static vs. dynamic) and adjusts scores accordingly.

2. **Codebundle-Level Analysis**  
   - Evaluates how many tasks a runbook contains, applying scores for ideal or excessive count.

3. **Linting According to CodeBundle Development Checklist**  
   - Checks suite-level documentation, metadata, tasks, issue-raising, `RW.Core.Add Pre To Report`, `RW.Core.Push Metric`, and more.

At the end, it **prints** three tables (Task-Level, Codebundle-Level, and Lint Results) and **persists** all results to a JSON file.

---

## Prerequisites

1. **Python 3.7+**  
   - Install [Robot Framework](https://robotframework.org/) or at least `robot.api`.  
2. **Requests** library:
   ```bash
   pip install requests
   ```
3. **Tabulate** library (optional but recommended for pretty table output):
   ```bash
   pip install tabulate
   ```
4. **Access** to the desired `.robot` files, which must reside in the directory you want to scan.

5. **LLM Endpoint** (Optional)  
   - The script defaults to an OpenAI-like endpoint set in `EXPLAIN_URL` (e.g., "https://papi.beta.runwhen.com/bow/raw?").  
   - You can customize this URL, along with `HEADERS`, or disable the LLM calls if desired.

---

## Configuration & Script Overview

The script’s main components:

- **`EXPLAIN_URL`, `HEADERS`**  
  Where LLM requests are sent. Edit these if using another backend.  
- **`PERSISTENT_FILE`**  
  File path (`task_analysis.json`) where final results are stored.  
- **`REFERENCE_FILE`**  
  File path (`reference_scores.json`) containing any pre-defined “reference tasks” with known scores.

### Directory to Analyze

By default, the script sets:
```python
codebundles_dir = "../../test"
```
in the `main()` function. **Change** this to your actual directory (or pass it via CLI, if you extend the script).

---

## Running the Script

1. **Clone or Copy** the script into your local environment.  
2. **Install Dependencies**:
   ```bash
   pip install requests robotframework tabulate
   ```
   (Robot Framework ≥4.0 recommended.)
3. **Edit** `codebundles_dir` in the `main()` function or create a CLI argument for it.
4. **Run**:
   ```bash
   python lint_scoring.py
   ```
   (Replace `lint_scoring.py` with the actual filename.)

### On Completion

- A console output with **three** sections appears:
  1. **Task-Level Analysis**  
  2. **Codebundle-Level Analysis (Runbooks)**  
  3. **Codebundle Linting**

- A JSON file named `task_analysis.json` is created (or overwritten) in the same folder as the script. This file contains:

  ```json
  {
    "task_results": [...],
    "codebundle_results": [...],
    "lint_results": [...]
  }
  ```

---

## Interpreting the Output

### 1. Task-Level Analysis

```
=== Task-Level Analysis ===

╒══════════════╤══════════════╤═════════════════════════════╤════════╕
│ Codebundle   │ File         │ Task                        │ Score  │
╞══════════════╪══════════════╪═════════════════════════════╪════════╡
│ my-bundle    │ runbook.robot│ Check Deployment Log...     │ 4/5    │
├──────────────┼──────────────┼─────────────────────────────┼────────┤
│ my-bundle    │ runbook.robot│ Inspect Container Restarts… │ 3/5    │
╘══════════════╧══════════════╧═════════════════════════════╧════════╛
```

- Each **Task** is assigned a **score** from **1 to 5** based on LLM-based clarity plus (for runbooks) whether it raises an issue dynamically (increasing the score) or not at all (penalizing).

#### Detailed Explanations for Scores ≤ 3
If tasks have a score of **3 or lower**, the script prints extra detail:

```
--- Detailed Explanations for Scores <= 3 ---

• Codebundle: my-bundle
  File: runbook.robot
  Task: Inspect Container Restarts…
  Score: 3/5
  Reasoning:
    Missing a 'Where' variable. The task has potential for more specificity.
  Suggested Title:
    Inspect Container Restarts in ${NAMESPACE}
------------------------------------------------------------
```

- **Reasoning** indicates which checks contributed to the final score.  
- **Suggested Title** helps authors rename or add specificity.

### 2. Codebundle-Level Analysis (Runbooks)

```
=== Codebundle-Level Analysis (Runbooks) ===

╒══════════════╤══════════════╤═════════════╤════════════════════╤════════════════════════════════════════════════════╕
│ Codebundle   │ File         │   Num Tasks │ Codebundle Score   │ Reasoning                                          │
╞══════════════╪══════════════╪═════════════╪════════════════════╪════════════════════════════════════════════════════╡
│ k8s-troubles │ runbook.robot│           12│ 2/5                │ 12 tasks => likely too large for a single runbook. │
├──────────────┼──────────────┼─────────────┼────────────────────┼────────────────────────────────────────────────────┤
│ my-bundle    │ runbook.robot│           4 │ 3/5                │ 4 tasks => basic coverage.                         │
╘══════════════╧══════════════╧═════════════╧════════════════════╧════════════════════════════════════════════════════╛
```

- **Num Tasks** is how many tasks in that runbook.  
- The **Codebundle Score** is a numeric rating from **1** to **5**, based on recommended sweet spots (7–8 tasks) or minimal coverage (≥3 tasks).  
- The **Reasoning** column clarifies why it scored that way.

### 3. Codebundle Linting

```
=== Codebundle Linting ===

╒══════════════╤══════════════╤═════════════╤════════════════════════════════════════════════════════════════════════════╕
│ Codebundle   │ File         │ Lint Score  │ Reasons                                                                      │
╞══════════════╪══════════════╪═════════════╪════════════════════════════════════════════════════════════════════════════╡
│ my-bundle    │ runbook.robot│ 4/5         │ - Missing Metadata 'Supports' in *** Settings ***.                          │
│              │              │             │ - Task 'Check Logging' has no [Documentation].                              │
├──────────────┼──────────────┼─────────────┼────────────────────────────────────────────────────────────────────────────┤
│ another-bund │ sli.robot    │ 3/5         │ - SLI task 'Push Memory Metric' did not call RW.Core.Push Metric.          │
╘══════════════╧══════════════╧═════════════╧════════════════════════════════════════════════════════════════════════════╛
```

- A separate **lint check** examines:

  - **Settings**:
    - Suite-level documentation (missing => penalty)  
    - Metadata (Author, Display Name, Supports)  
    - Suite Setup is defined  
  - **Tasks**:
    - Each task’s `[Documentation]`  
    - For **Runbooks**, a requirement to raise an issue or add something to the report  
    - For **SLIs**, at least one call to `RW.Core.Push Metric`

- The **Lint Score** is also from **1 to 5**. Any missing items or bad practices reduce the score.  
- **Reasons** detail each deficiency.

---

## Modifying the Analysis Rules

1. **LLM Endpoints**  
   Change `EXPLAIN_URL` and `HEADERS` if pointing to a different AI service.  
2. **Reference Examples**  
   `reference_scores.json` can contain known tasks with pre-defined scores to skip repeated LLM calls.  
3. **Runbook Issue Logic**  
   In `apply_runbook_issue_rules()`, update how much you penalize or reward tasks that raise dynamic or static issues.  
4. **Lint Checks**  
   In `lint_codebundle()`, adjust the severity or rules for missing metadata, doc, or user variable imports.  
   Add more detail for “Supports” content or specific tag checks.

---



## Cache Notes
- All .robot files are re-parsed each run.
- Each task is identified by title alone.
- If the title is found in the persistent cache, we reuse that score. Otherwise, we call the LLM.
- The entire result set (existing + newly added tasks) is saved back to JSON.
- Deleted tasks or codebundles typically vanish if you only store the newly found tasks in the final JSON. Or they stick around if you’re merging data and not removing old entries.