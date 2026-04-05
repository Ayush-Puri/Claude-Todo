#!/bin/bash
# Sync task JSON files from ~/claude-auto/tasks/ into a format the dashboard can import.
# Called by runner.sh before execution to ensure task files exist.
# Also generates a manifest for easy import.

TASKS_DIR="$HOME/claude-auto/tasks"
mkdir -p "$TASKS_DIR"

# If no task files exist but there's a nightly-task.md, that's the legacy format — skip
if [ -z "$(ls "$TASKS_DIR"/*.json 2>/dev/null)" ]; then
  echo "No task JSON files found in $TASKS_DIR"
  exit 0
fi

echo "Task files in $TASKS_DIR:"
for f in "$TASKS_DIR"/*.json; do
  [ -f "$f" ] || continue
  TITLE=$(python3 -c "import json; print(json.load(open('$f'))['title'])" 2>/dev/null || echo "?")
  COUNT=$(python3 -c "import json; print(len(json.load(open('$f'))['tasks']))" 2>/dev/null || echo "?")
  ACTIVE=$(python3 -c "import json; print('ACTIVE' if json.load(open('$f')).get('isActive') else '')" 2>/dev/null || echo "")
  echo "  $(basename "$f"): $TITLE ($COUNT tasks) $ACTIVE"
done
