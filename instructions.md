# Claude Todo — Task Population Instructions

When asked to add, update, or manage tasks in Claude Todo, follow these rules exactly.

## File Location
- Task files live in: `~/claude-auto/tasks/`
- One JSON file per group, named: `{group-id}.json`
- Example: `~/claude-auto/tasks/g_20260405_api.json`

## JSON Schema

```json
{
  "id": "g_20260405_api",
  "title": "Day 1 - API Refactor",
  "date": "2026-04-05",
  "timeStart": "02:00",
  "timeEnd": "06:30",
  "isActive": true,
  "tasks": [
    {
      "id": "t_001",
      "title": "Short descriptive title",
      "prompt": "Full detailed instructions for Claude to execute this task...",
      "status": "pending",
      "verification": "Specific command or check to verify completion",
      "expectedResult": "What success looks like in concrete terms",
      "retryCount": 0,
      "logs": {
        "sessionId": null,
        "startedAt": null,
        "completedAt": null
      }
    }
  ]
}
```

## Task Status Values
- `pending` — Not yet executed
- `running` — Currently being executed by runner
- `verifying` — Task done, verification in progress
- `done` — Completed and verified
- `failed` — Verification failed after retry
- `needs-review` — Failed twice, needs human review

## Rules for Writing Tasks

1. **Be specific in prompts**: Always start with the working directory (`Go to ~/projects/X`). Include exact file paths, function names, and desired behavior.

2. **One objective per task**: Each task should do ONE thing. "Refactor auth AND add tests" should be two separate tasks.

3. **Order by dependency**: If Task B depends on Task A's output, Task A must come first in the array.

4. **Always include verification**: Every task MUST have a `verification` field with a concrete check:
   - For code changes: `Run npm test` or `Run pytest`
   - For file creation: `Check that ~/path/to/file.md exists and is non-empty`
   - For refactoring: `Run grep -r 'old_pattern' src/ and confirm zero matches`

5. **Always include expectedResult**: Describe what success looks like:
   - `"All 42 tests pass with 0 failures"`
   - `"File exists with >100 lines of API documentation"`
   - `"No callback-based patterns found in src/services/"`

6. **Only set ONE group as active**: `"isActive": true` on exactly one group. The runner processes only the active group.

7. **Generate unique IDs**: Use format `g_{date}_{keyword}` for groups, `t_{sequence}` for tasks.

8. **Ask for a report as the last task**: Add a final task that writes a summary report to `~/claude-auto/logs/report-$(date +%Y%m%d).md`.

## Example: Creating a New Group

```bash
# Write the file directly
cat > ~/claude-auto/tasks/g_20260405_tests.json << 'EOF'
{
  "id": "g_20260405_tests",
  "title": "Day 1 - Write Missing Tests",
  "date": "2026-04-05",
  "timeStart": "02:00",
  "timeEnd": "06:30",
  "isActive": true,
  "tasks": [
    {
      "id": "t_001",
      "title": "Write auth service tests",
      "prompt": "Go to ~/projects/my-app. Read src/services/auth.js. Write comprehensive unit tests in tests/services/auth.test.js covering all exported functions. Use Jest. Run the tests and fix any failures.",
      "status": "pending",
      "verification": "Run cd ~/projects/my-app && npx jest tests/services/auth.test.js",
      "expectedResult": "All tests pass with >80% code coverage on auth.js",
      "retryCount": 0,
      "logs": {"sessionId": null, "startedAt": null, "completedAt": null}
    },
    {
      "id": "t_002",
      "title": "Write summary report",
      "prompt": "Write a summary of all tests written, their pass/fail status, and coverage metrics to ~/claude-auto/logs/report-$(date +%Y%m%d).md",
      "status": "pending",
      "verification": "Check that ~/claude-auto/logs/report-*.md exists and is non-empty",
      "expectedResult": "Report file exists with test summary",
      "retryCount": 0,
      "logs": {"sessionId": null, "startedAt": null, "completedAt": null}
    }
  ]
}
EOF
```

## Updating Task Status
After execution, the runner updates the JSON directly. You can also update status manually:
- To mark a task done: change `"status": "done"`
- To re-run a task: change `"status": "pending"` and `"retryCount": 0`
- To skip a task: change `"status": "done"` without running it
