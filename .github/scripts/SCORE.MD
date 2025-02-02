# Cache Notes
- All .robot files are re-parsed each run.
- Each task is identified by title alone.
- If the title is found in the persistent cache, we reuse that score. Otherwise, we call the LLM.
- The entire result set (existing + newly added tasks) is saved back to JSON.
- Deleted tasks or codebundles typically vanish if you only store the newly found tasks in the final JSON. Or they stick around if you’re merging data and not removing old entries.