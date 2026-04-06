#!/bin/bash
set -euo pipefail

# ============================================================
# Shared Claude Todo Dispatcher
# Pulls task batches from GitHub, runs max 3 concurrent sessions,
# waits for all to complete, then fetches next round.
# ============================================================

CLAUDE_BIN="$HOME/.local/bin/claude"
SHARED_REPO_DIR="$HOME/claude-auto/shared-repo"
SHARED_REPO_URL="https://github.com/Ayush-Puri/shared-Claude-Todo.git"
RAW_LOG_DIR="$HOME/claude-auto/logs/raw"
OBSIDIAN_DIR="$HOME/Documents/Obsidian/Syfe/Claude Logs"
PARSE_SCRIPT="$HOME/claude-auto/parse-log.py"
SESSIONS_FILE="$HOME/claude-auto/sessions.json"
MAX_CONCURRENT=3
LOCK_FILE="$HOME/claude-auto/.shared-dispatcher.lock"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MASTER_LOG="$HOME/claude-auto/logs/shared_${TIMESTAMP}.log"

log() { echo -e "[$(date '+%H:%M:%S')] $1" | tee -a "$MASTER_LOG"; }

mkdir -p "$RAW_LOG_DIR" "$OBSIDIAN_DIR"

# === Prevent concurrent dispatchers ===
if [ -f "$LOCK_FILE" ]; then
  LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    log "${DIM}Dispatcher already running (PID $LOCK_PID). Exiting.${NC}"
    exit 0
  fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# === Clone or pull the shared repo ===
sync_repo() {
  if [ -d "$SHARED_REPO_DIR/.git" ]; then
    cd "$SHARED_REPO_DIR"
    git fetch origin 2>/dev/null
    git reset --hard origin/main 2>/dev/null
    cd - >/dev/null
  else
    rm -rf "$SHARED_REPO_DIR"
    git clone "$SHARED_REPO_URL" "$SHARED_REPO_DIR" 2>/dev/null
  fi
}

# === Push status changes back to GitHub ===
push_status() {
  cd "$SHARED_REPO_DIR"
  git add -A 2>/dev/null
  if ! git diff --cached --quiet 2>/dev/null; then
    git commit -m "status: update task states [$(date '+%Y-%m-%d %H:%M')]" 2>/dev/null
    git push origin main 2>/dev/null || log "${YELLOW}Warning: push failed (may need auth)${NC}"
  fi
  cd - >/dev/null
}

# === Get current model from sessions.json ===
get_model_override() {
  local batch_model="$1"
  if [ -n "$batch_model" ] && [ "$batch_model" != "null" ]; then
    echo "$batch_model"
  else
    echo "haiku"
  fi
}

# === Run a single batch (all tasks in one session) ===
run_batch() {
  local BATCH_FILE="$1"
  local BATCH_NAME=$(basename "$BATCH_FILE" .json)
  local BATCH_LOG="$RAW_LOG_DIR/shared_${TIMESTAMP}_${BATCH_NAME}.log"

  log "${CYAN}━━━ Batch: $BATCH_NAME ━━━${NC}"

  # Parse batch
  local BATCH_JSON=$(cat "$BATCH_FILE")
  local BATCH_ID=$(echo "$BATCH_JSON" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('batch','unknown'))")
  local BATCH_DESC=$(echo "$BATCH_JSON" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('description',''))")
  local BATCH_MODEL=$(echo "$BATCH_JSON" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('model','haiku'))")
  local BATCH_PROJECT=$(echo "$BATCH_JSON" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('project',''))")
  local TASK_COUNT=$(echo "$BATCH_JSON" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read()).get('tasks',[])))")

  local MODEL=$(get_model_override "$BATCH_MODEL")

  log "  ${BOLD}$BATCH_DESC${NC}"
  log "  Model: $MODEL | Tasks: $TASK_COUNT"

  # Move to running/
  mv "$BATCH_FILE" "$SHARED_REPO_DIR/running/$(basename "$BATCH_FILE")"
  local RUNNING_FILE="$SHARED_REPO_DIR/running/$(basename "$BATCH_FILE")"

  # Generate session ID
  local SESSION_UUID=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
  local ALL_PASSED=true
  local TASK_NUM=0

  # Process each task in the batch
  local TASK_IDS=$(echo "$BATCH_JSON" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
for i,t in enumerate(d.get('tasks',[])):
    print(i)
")

  for TASK_IDX in $TASK_IDS; do
    TASK_NUM=$((TASK_NUM + 1))
    local TASK_TITLE=$(echo "$BATCH_JSON" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['tasks'][$TASK_IDX]['title'])")
    local TASK_PROMPT=$(echo "$BATCH_JSON" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['tasks'][$TASK_IDX]['prompt'])")
    local TASK_VERIFY=$(echo "$BATCH_JSON" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['tasks'][$TASK_IDX].get('verification',''))")
    local TASK_EXPECTED=$(echo "$BATCH_JSON" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['tasks'][$TASK_IDX].get('expectedResult',''))")

    local SAFE_TITLE=$(echo "$TASK_TITLE" | tr ' /' '-_' | tr -cd '[:alnum:]-_')
    local RAW_LOG="$RAW_LOG_DIR/shared_${TIMESTAMP}_${BATCH_NAME}_${TASK_NUM}_${SAFE_TITLE}.jsonl"
    local DEBUG_LOG="${RAW_LOG%.jsonl}_debug.txt"

    log "  ${BOLD}Task $TASK_NUM/$TASK_COUNT: $TASK_TITLE${NC}"

    # Prepend project directory if specified
    local FULL_PROMPT="$TASK_PROMPT"
    if [ -n "$BATCH_PROJECT" ] && [ "$BATCH_PROJECT" != "null" ]; then
      FULL_PROMPT="Working directory: $BATCH_PROJECT\n\n$TASK_PROMPT"
    fi

    # Execute
    local TASK_EXIT=0
    if [ "$TASK_NUM" -eq 1 ]; then
      "$CLAUDE_BIN" --print --dangerously-skip-permissions --model "$MODEL" \
        --session-id "$SESSION_UUID" \
        --output-format stream-json --include-partial-messages --verbose \
        --debug-file "$DEBUG_LOG" \
        "$FULL_PROMPT" > "$RAW_LOG" 2>&1 || TASK_EXIT=$?
    else
      "$CLAUDE_BIN" --print --dangerously-skip-permissions --model "$MODEL" \
        --resume "$SESSION_UUID" \
        --output-format stream-json --include-partial-messages --verbose \
        --debug-file "$DEBUG_LOG" \
        "$FULL_PROMPT" > "$RAW_LOG" 2>&1 || TASK_EXIT=$?
    fi

    # Verify if verification exists
    if [ -n "$TASK_VERIFY" ] && [ "$TASK_VERIFY" != "null" ] && [ "$TASK_VERIFY" != "" ]; then
      local VERIFY_RESULT=$("$CLAUDE_BIN" --print --dangerously-skip-permissions --model "$MODEL" \
        --resume "$SESSION_UUID" \
        "Verify: $TASK_VERIFY. Expected: $TASK_EXPECTED. Respond ONLY with JSON: {\"passed\":true/false,\"reason\":\"...\"}" 2>&1) || true

      local PASSED=$(echo "$VERIFY_RESULT" | python3 -c "
import json,sys,re; text=sys.stdin.read()
m=re.search(r'\{.*\"passed\".*\}',text,re.DOTALL)
if m:
    try: print('true' if json.loads(m.group()).get('passed') else 'false')
    except: print('false')
else: print('false')
" 2>/dev/null || echo "false")

      if [ "$PASSED" = "true" ]; then
        log "    ${GREEN}✓ Passed${NC}"
      else
        log "    ${RED}✗ Failed${NC}"
        ALL_PASSED=false
      fi
    else
      if [ "$TASK_EXIT" -ne 0 ]; then ALL_PASSED=false; fi
      log "    Exit: $TASK_EXIT"
    fi

    # Parse to Obsidian
    python3 "$PARSE_SCRIPT" \
      --raw-log "$RAW_LOG" --debug-log "$DEBUG_LOG" \
      --task-title "$TASK_TITLE" --group-title "Shared: $BATCH_ID" \
      --group-date "$(date +%Y-%m-%d)" --session-num "$TASK_NUM" \
      --obsidian-dir "$OBSIDIAN_DIR" 2>/dev/null || true
  done

  # === Package response output ===
  log "  Packaging response..."
  mkdir -p "$SHARED_REPO_DIR/responses"

  local OUTPUT_NAME=$(basename "$BATCH_FILE" .json)-output.md
  local OUTPUT_FILE="$SHARED_REPO_DIR/responses/$OUTPUT_NAME"

  python3 -c "
import json, sys, os, glob

batch_name = sys.argv[1]
timestamp = sys.argv[2]
log_dir = sys.argv[3]
batch_file = sys.argv[4]
output_path = sys.argv[5]

# Read the original batch for metadata
batch_data = {}
try:
    with open(batch_file) as f:
        batch_data = json.load(f)
except: pass

# Collect all raw logs for this batch
log_pattern = os.path.join(log_dir, f'shared_{timestamp}_{batch_name}_*.jsonl')
log_files = sorted(glob.glob(log_pattern))

lines = []
lines.append(f'# Response: {batch_data.get(\"description\", batch_name)}')
lines.append(f'')
lines.append(f'**Batch:** {batch_data.get(\"batch\", batch_name)}')
lines.append(f'**Author:** {batch_data.get(\"author\", \"unknown\")}')
lines.append(f'**Model:** {batch_data.get(\"model\", \"haiku\")}')
lines.append(f'**Repos:** {\", \".join(batch_data.get(\"repos\", [])) or \"general\"}')
lines.append(f'**Executed:** {sys.argv[2][:8]}')
lines.append(f'**Pipeline:** {batch_data.get(\"pipeline\", \"unknown\")}')
lines.append(f'')
lines.append(f'---')
lines.append(f'')

task_num = 0
tasks = batch_data.get('tasks', [])

for log_file in log_files:
    task_num += 1
    task_title = tasks[task_num-1]['title'] if task_num-1 < len(tasks) else f'Task {task_num}'

    lines.append(f'## Task {task_num}: {task_title}')
    lines.append(f'')

    # Extract text output and tool use from stream-json
    texts = []
    tools = []
    files_created = []
    errors = []

    try:
        with open(log_file) as f:
            for line in f:
                try:
                    ev = json.loads(line.strip())
                    if ev.get('type') == 'assistant':
                        for b in ev.get('message', {}).get('content', []):
                            if b.get('type') == 'text':
                                texts.append(b['text'])
                            elif b.get('type') == 'tool_use':
                                name = b.get('name', '')
                                inp = b.get('input', {})
                                if name == 'Write':
                                    files_created.append(inp.get('file_path', ''))
                                    tools.append(f'Write: {inp.get(\"file_path\", \"\")}')
                                elif name == 'Bash':
                                    cmd = inp.get('command', '')
                                    if len(cmd) > 100: cmd = cmd[:100] + '...'
                                    tools.append(f'Bash: {cmd}')
                                elif name in ('Read', 'Edit', 'Grep', 'Glob'):
                                    tools.append(f'{name}: {inp.get(\"file_path\", inp.get(\"pattern\", \"\"))}')
                                elif name == 'WebSearch':
                                    tools.append(f'WebSearch: {inp.get(\"query\", \"\")}')
                                elif name == 'WebFetch':
                                    tools.append(f'WebFetch: {inp.get(\"url\", \"\")}')
                                else:
                                    tools.append(name)
                    if ev.get('type') == 'result':
                        if ev.get('subtype') == 'error':
                            errors.append(ev.get('error', ''))
                except: pass
    except: pass

    # Output section
    full_text = '\\n\\n'.join(texts)
    if full_text:
        lines.append('### Output')
        lines.append('')
        lines.append(full_text)
        lines.append('')

    # Tools used
    if tools:
        lines.append('### Tools Used')
        lines.append('')
        for t in tools[:30]:
            lines.append(f'- \`{t}\`')
        if len(tools) > 30:
            lines.append(f'- ... and {len(tools)-30} more')
        lines.append('')

    # Files created
    if files_created:
        lines.append('### Files Created')
        lines.append('')
        for fp in files_created:
            lines.append(f'- \`{fp}\`')
        lines.append('')

    # Errors
    if errors:
        lines.append('### Errors')
        lines.append('')
        for e in errors:
            lines.append(f'> {e}')
        lines.append('')

    lines.append('---')
    lines.append('')

lines.append(f'*Generated by Claude Todo Shared Dispatcher*')

with open(output_path, 'w') as f:
    f.write('\\n'.join(lines))

print(f'Response written: {output_path}')
" "$BATCH_NAME" "$TIMESTAMP" "$RAW_LOG_DIR" "$RUNNING_FILE" "$OUTPUT_FILE" 2>&1 | tee -a "$MASTER_LOG" || log "  Warning: response packaging failed"

  # === Post to Slack if batch has slackContext ===
  local HAS_SLACK=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print('yes' if d.get('slackContext',{}).get('channelId') else 'no')
" "$RUNNING_FILE" 2>/dev/null || echo "no")

  if [ "$HAS_SLACK" = "yes" ]; then
    log "  Posting response to Slack thread..."
    "$HOME/claude-auto/slack-responder.sh" "$OUTPUT_FILE" "$RUNNING_FILE" 2>&1 | tee -a "$MASTER_LOG" || log "  Warning: Slack response failed"
  fi

  # Move to done/ or failed/
  if [ "$ALL_PASSED" = "true" ]; then
    mv "$RUNNING_FILE" "$SHARED_REPO_DIR/done/$(basename "$RUNNING_FILE")"
    log "  ${GREEN}Batch complete ✓${NC}"
  else
    mv "$RUNNING_FILE" "$SHARED_REPO_DIR/failed/$(basename "$RUNNING_FILE")"
    log "  ${RED}Batch failed ✗${NC}"
  fi
}

# ============================================================
# MAIN LOOP
# ============================================================

log "${BOLD}=== Shared Claude Todo Dispatcher ===${NC}"
log "Repo: $SHARED_REPO_URL"
log "Max concurrent: $MAX_CONCURRENT"
echo ""

# Sync repo
log "Pulling from GitHub..."
sync_repo
log "Synced."

# Find pending batches in queue/, sorted by priority (filename)
BATCH_FILES=$(ls "$SHARED_REPO_DIR/queue/"*.json 2>/dev/null | sort || true)

if [ -z "$BATCH_FILES" ]; then
  log "No pending batches in queue/. Done."
  push_status
  exit 0
fi

BATCH_COUNT=$(echo "$BATCH_FILES" | wc -l | tr -d ' ')
log "Found $BATCH_COUNT batch(es) in queue"
echo ""

# Process in rounds of MAX_CONCURRENT
while [ -n "$BATCH_FILES" ]; do
  # Take up to MAX_CONCURRENT batches
  ROUND_FILES=$(echo "$BATCH_FILES" | head -n "$MAX_CONCURRENT")
  REMAINING_FILES=$(echo "$BATCH_FILES" | tail -n +$((MAX_CONCURRENT + 1)) || true)

  ROUND_COUNT=$(echo "$ROUND_FILES" | wc -l | tr -d ' ')
  log "${BOLD}=== Round: $ROUND_COUNT batch(es) ===${NC}"
  echo ""

  # Launch batches concurrently (in background)
  PIDS=()
  for BATCH_FILE in $ROUND_FILES; do
    run_batch "$BATCH_FILE" &
    PIDS+=($!)
    log "  Launched PID $! for $(basename "$BATCH_FILE")"
  done

  # Wait for ALL in this round to complete
  log ""
  log "${YELLOW}Waiting for $ROUND_COUNT session(s) to complete...${NC}"
  for PID in "${PIDS[@]}"; do
    wait "$PID" 2>/dev/null || true
  done
  log "${GREEN}Round complete.${NC}"
  echo ""

  # Push status after each round
  push_status

  BATCH_FILES="$REMAINING_FILES"
done

# Final sync
push_status

# Notification
osascript -e "display notification \"Shared queue processed: $BATCH_COUNT batch(es)\" with title \"Claude Todo\" sound name \"Glass\"" 2>/dev/null || true

log "${BOLD}=== Dispatcher complete ===${NC}"
