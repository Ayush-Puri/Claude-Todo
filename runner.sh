#!/bin/bash
set -euo pipefail

# === Configuration ===
CLAUDE_BIN="$HOME/.local/bin/claude"
TASKS_DIR="$HOME/claude-auto/tasks"
SESSIONS_FILE="$HOME/claude-auto/sessions.json"
RAW_LOG_DIR="$HOME/claude-auto/logs/raw"
OBSIDIAN_DIR="$HOME/Documents/Obsidian/Syfe/Claude Logs"
PARSE_SCRIPT="$HOME/claude-auto/parse-log.py"
RCLONE_REMOTE="gdrive"
RCLONE_DEST="Claude Todo Logs"

mkdir -p "$RAW_LOG_DIR" "$OBSIDIAN_DIR"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MASTER_LOG="$HOME/claude-auto/logs/runner_${TIMESTAMP}.log"

log() { echo "[$(date '+%H:%M:%S')] $1" | tee -a "$MASTER_LOG"; }

# === Determine Current Session Window ===
CURRENT_HOUR=$(date +%H)
CURRENT_MIN=$(date +%M)
CURRENT_TOTAL=$(( 10#$CURRENT_HOUR * 60 + 10#$CURRENT_MIN ))

SESSION_INFO=$(python3 -c "
import json, sys

now_mins = int(sys.argv[1])
data = json.load(open(sys.argv[2]))

for s in data['sessions']:
    start = s['startHour'] * 60 + s['startMinute']
    end = s['endHour'] * 60 + s['endMinute']

    # Handle overnight sessions (e.g., 23:30 -> 04:30)
    if end < start:
        if now_mins >= start or now_mins < end:
            print(json.dumps(s))
            sys.exit(0)
    else:
        if start <= now_mins < end:
            print(json.dumps(s))
            sys.exit(0)

print('null')
" "$CURRENT_TOTAL" "$SESSIONS_FILE" 2>/dev/null || echo 'null')

if [ "$SESSION_INFO" = "null" ] || [ -z "$SESSION_INFO" ]; then
  log "No active session window at $(date '+%H:%M'). Exiting."
  exit 0
fi

SESSION_ID=$(echo "$SESSION_INFO" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['id'])")
SESSION_NAME=$(echo "$SESSION_INFO" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['name'])")
SESSION_MODEL=$(echo "$SESSION_INFO" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['model'])")
MAX_BUDGET=$(echo "$SESSION_INFO" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['maxBudgetUsd'])")
TIMEOUT_PER_TASK=$(echo "$SESSION_INFO" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['timeoutSeconds'])")

log "=== Claude Todo Runner ==="
log "Session: #${SESSION_ID} ${SESSION_NAME} (model: ${SESSION_MODEL})"
log "Time: $(date '+%H:%M') | Budget: \$${MAX_BUDGET}/task | Timeout: ${TIMEOUT_PER_TASK}s/task"

# === Find Active Group ===
ACTIVE_FILE=""
for f in "$TASKS_DIR"/*.json; do
  [ -f "$f" ] || continue
  if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('isActive') else 1)" "$f" 2>/dev/null; then
    ACTIVE_FILE="$f"
    break
  fi
done

if [ -z "$ACTIVE_FILE" ]; then
  log "No active task group found in $TASKS_DIR. Exiting."
  exit 0
fi

GROUP_TITLE=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['title'])" "$ACTIVE_FILE")
GROUP_ID=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['id'])" "$ACTIVE_FILE")
GROUP_DATE=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('date','undated'))" "$ACTIVE_FILE")

log "Active group: $GROUP_TITLE ($GROUP_ID)"

# === Helper: Update task field in JSON ===
update_task() {
  local task_id="$1" field="$2" value="$3"
  python3 -c "
import json, sys
with open(sys.argv[1], 'r') as f: data = json.load(f)
for t in data['tasks']:
    if t['id'] == sys.argv[2]:
        keys = sys.argv[3].split('.')
        obj = t
        for k in keys[:-1]: obj = obj[k]
        try: obj[keys[-1]] = json.loads(sys.argv[4])
        except: obj[keys[-1]] = sys.argv[4]
        break
with open(sys.argv[1], 'w') as f: json.dump(data, f, indent=2)
" "$ACTIVE_FILE" "$task_id" "$field" "$value"
}

# === Get pending tasks ===
TASK_IDS=$(python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
for t in data['tasks']:
    if t['status'] in ('pending', 'failed'):
        print(t['id'])
" "$ACTIVE_FILE")

if [ -z "$TASK_IDS" ]; then
  log "No pending tasks. Done."
  exit 0
fi

TASK_COUNT=$(echo "$TASK_IDS" | wc -l | tr -d ' ')
log "Found $TASK_COUNT pending task(s)"

# === Process each task ===
TASK_NUM=0
for TASK_ID in $TASK_IDS; do
  TASK_NUM=$((TASK_NUM + 1))

  # Check if we're still in our session window
  NOW_H=$(date +%H); NOW_M=$(date +%M)
  NOW_TOTAL=$(( 10#$NOW_H * 60 + 10#$NOW_M ))
  STILL_IN_WINDOW=$(python3 -c "
import json, sys
now = int(sys.argv[1])
s = json.loads(sys.argv[2])
start = s['startHour']*60 + s['startMinute']
end = s['endHour']*60 + s['endMinute']
if end < start:
    print('yes' if (now >= start or now < end) else 'no')
else:
    print('yes' if start <= now < end else 'no')
" "$NOW_TOTAL" "$SESSION_INFO")

  if [ "$STILL_IN_WINDOW" != "yes" ]; then
    log "Session window expired at $(date '+%H:%M'). Stopping. Remaining tasks will run in next session."
    break
  fi

  # Read task details
  TASK_JSON=$(python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
for t in data['tasks']:
    if t['id'] == sys.argv[2]: print(json.dumps(t)); break
" "$ACTIVE_FILE" "$TASK_ID")

  TASK_TITLE=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['title'])")
  TASK_PROMPT=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['prompt'])")
  TASK_VERIFY=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('verification',''))")
  TASK_EXPECTED=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('expectedResult',''))")
  RETRY_COUNT=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('retryCount',0))")

  SAFE_TITLE=$(echo "$TASK_TITLE" | tr ' /' '-_' | tr -cd '[:alnum:]-_')
  RAW_LOG="$RAW_LOG_DIR/${TIMESTAMP}_S${SESSION_ID}_${TASK_NUM}_${SAFE_TITLE}.jsonl"
  DEBUG_LOG="$RAW_LOG_DIR/${TIMESTAMP}_S${SESSION_ID}_${TASK_NUM}_${SAFE_TITLE}_debug.txt"

  log "--- Task $TASK_NUM/$TASK_COUNT: $TASK_TITLE ---"
  log "  Model: $SESSION_MODEL | Task ID: $TASK_ID"

  # Update status
  update_task "$TASK_ID" "status" '"running"'
  update_task "$TASK_ID" "logs.startedAt" "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
  update_task "$TASK_ID" "logs.sessionId" "\"S${SESSION_ID}_${TIMESTAMP}_${TASK_NUM}\""

  # === Execute task ===
  log "  Executing..."
  TASK_EXIT=0
  timeout "$TIMEOUT_PER_TASK" "$CLAUDE_BIN" \
    --print \
    --dangerously-skip-permissions \
    --model "$SESSION_MODEL" \
    --output-format stream-json \
    --include-partial-messages \
    --verbose \
    --debug-file "$DEBUG_LOG" \
    --max-budget-usd "$MAX_BUDGET" \
    "$TASK_PROMPT" \
    > "$RAW_LOG" 2>&1 || TASK_EXIT=$?

  log "  Execution finished (exit: $TASK_EXIT)"

  # === Verification ===
  if [ -n "$TASK_VERIFY" ] && [ "$TASK_VERIFY" != "null" ]; then
    update_task "$TASK_ID" "status" '"verifying"'
    log "  Verifying..."

    VERIFY_PROMPT="You are verifying if a task was completed correctly.
Task: $TASK_TITLE
Verification step: $TASK_VERIFY
Expected result: $TASK_EXPECTED
Perform the verification. Respond ONLY with JSON: {\"passed\": true/false, \"reason\": \"...\"}"

    VERIFY_RESULT=$("$CLAUDE_BIN" --print --dangerously-skip-permissions --model "$SESSION_MODEL" "$VERIFY_PROMPT" 2>&1) || true

    PASSED=$(echo "$VERIFY_RESULT" | python3 -c "
import json,sys,re
text=sys.stdin.read()
m=re.search(r'\{.*\"passed\".*\}',text,re.DOTALL)
if m:
    try: print('true' if json.loads(m.group()).get('passed') else 'false')
    except: print('false')
else: print('false')
" 2>/dev/null || echo "false")

    REASON=$(echo "$VERIFY_RESULT" | python3 -c "
import json,sys,re
text=sys.stdin.read()
m=re.search(r'\{.*\"passed\".*\}',text,re.DOTALL)
if m:
    try: print(json.loads(m.group()).get('reason',''))
    except: print('parse error')
else: print('no json found')
" 2>/dev/null || echo "unknown")

    log "  Verify: passed=$PASSED reason=$REASON"

    if [ "$PASSED" = "true" ]; then
      update_task "$TASK_ID" "status" '"done"'
      update_task "$TASK_ID" "logs.completedAt" "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
      log "  PASSED ✓"
    else
      if [ "$RETRY_COUNT" -lt 1 ]; then
        log "  FAILED — retrying..."
        update_task "$TASK_ID" "retryCount" "1"
        update_task "$TASK_ID" "status" '"running"'

        RETRY_PROMPT="$TASK_PROMPT

IMPORTANT: Previous attempt failed. Reason: $REASON
Expected: $TASK_EXPECTED
Fix the issues."

        RETRY_LOG="${RAW_LOG%.jsonl}_retry.jsonl"
        timeout "$TIMEOUT_PER_TASK" "$CLAUDE_BIN" \
          --print --dangerously-skip-permissions --model "$SESSION_MODEL" \
          --output-format stream-json --include-partial-messages --verbose \
          --debug-file "${DEBUG_LOG%.txt}_retry.txt" \
          --max-budget-usd "$MAX_BUDGET" \
          "$RETRY_PROMPT" > "$RETRY_LOG" 2>&1 || true

        update_task "$TASK_ID" "status" '"verifying"'
        VERIFY2=$("$CLAUDE_BIN" --print --dangerously-skip-permissions --model "$SESSION_MODEL" "$VERIFY_PROMPT" 2>&1) || true
        PASSED2=$(echo "$VERIFY2" | python3 -c "
import json,sys,re; text=sys.stdin.read(); m=re.search(r'\{.*\"passed\".*\}',text,re.DOTALL)
if m:
    try: print('true' if json.loads(m.group()).get('passed') else 'false')
    except: print('false')
else: print('false')
" 2>/dev/null || echo "false")

        if [ "$PASSED2" = "true" ]; then
          update_task "$TASK_ID" "status" '"done"'
          log "  PASSED on retry ✓"
        else
          update_task "$TASK_ID" "status" '"needs-review"'
          log "  FAILED after retry ✗"
        fi
      else
        update_task "$TASK_ID" "status" '"needs-review"'
        log "  Already retried — needs-review ✗"
      fi
      update_task "$TASK_ID" "logs.completedAt" "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
    fi
  else
    # No verification defined — just mark done if exit 0
    if [ "$TASK_EXIT" -eq 0 ]; then
      update_task "$TASK_ID" "status" '"done"'
    else
      update_task "$TASK_ID" "status" '"needs-review"'
    fi
    update_task "$TASK_ID" "logs.completedAt" "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
    log "  Completed (no verification defined)"
  fi

  # === Parse logs to Obsidian ===
  python3 "$PARSE_SCRIPT" \
    --raw-log "$RAW_LOG" --debug-log "$DEBUG_LOG" \
    --task-title "$TASK_TITLE" --group-title "$GROUP_TITLE" \
    --group-date "$GROUP_DATE" --session-num "$TASK_NUM" \
    --obsidian-dir "$OBSIDIAN_DIR" \
    2>&1 | tee -a "$MASTER_LOG" || log "  Warning: log parse failed"

  log ""
done

# === Google Drive sync ===
if command -v rclone &>/dev/null && rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}:"; then
  log "Syncing to Google Drive..."
  rclone copy "$OBSIDIAN_DIR" "${RCLONE_REMOTE}:${RCLONE_DEST}/" --update 2>&1 | tee -a "$MASTER_LOG" || log "Warning: GDrive sync failed"
fi

# === macOS notification ===
osascript -e "display notification \"Session #${SESSION_ID} (${SESSION_NAME}): processed ${TASK_NUM} tasks for ${GROUP_TITLE}\" with title \"Claude Todo\" sound name \"Glass\"" 2>/dev/null || true

log "=== Session #${SESSION_ID} complete ==="
