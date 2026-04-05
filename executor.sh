#!/bin/bash
set -euo pipefail

# ============================================================
# Claude Todo Task Executor
# Runs in a visible Terminal window, launched by Claude Todo app.
# Opens ONE Claude session and sends tasks sequentially.
# ============================================================

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
MASTER_LOG="$HOME/claude-auto/logs/executor_${TIMESTAMP}.log"

# Colors for terminal output
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

banner() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║${NC}  ${BOLD}Claude Todo — Task Executor${NC}                      ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  $(date '+%Y-%m-%d %H:%M:%S')                            ${CYAN}║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
}

log() { echo -e "$1" | tee -a "$MASTER_LOG"; }

# === Determine session and model ===
CURRENT_TOTAL=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
SESSION_INFO=$(python3 -c "
import json, sys
now = int(sys.argv[1])
data = json.load(open(sys.argv[2]))
for s in data['sessions']:
    start = s['startHour']*60 + s['startMinute']
    end = s['endHour']*60 + s['endMinute']
    if end < start:
        if now >= start or now < end: print(json.dumps(s)); sys.exit(0)
    else:
        if start <= now < end: print(json.dumps(s)); sys.exit(0)
print('null')
" "$CURRENT_TOTAL" "$SESSIONS_FILE" 2>/dev/null || echo 'null')

# Default to haiku if no session window matches
if [ "$SESSION_INFO" = "null" ] || [ -z "$SESSION_INFO" ]; then
  MODEL="haiku"
  SESSION_NAME="Ad-hoc"
  SESSION_ID=0
  MAX_BUDGET=10
  log "${YELLOW}No active session window — running as ad-hoc with model: haiku${NC}"
else
  MODEL=$(echo "$SESSION_INFO" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['model'])")
  SESSION_NAME=$(echo "$SESSION_INFO" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['name'])")
  SESSION_ID=$(echo "$SESSION_INFO" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['id'])")
  MAX_BUDGET=$(echo "$SESSION_INFO" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['maxBudgetUsd'])")
fi

# Allow override via arguments
GROUP_FILE="${1:-}"
[ -n "${2:-}" ] && MODEL="$2"

banner

# === Find active group ===
if [ -n "$GROUP_FILE" ] && [ -f "$GROUP_FILE" ]; then
  ACTIVE_FILE="$GROUP_FILE"
else
  ACTIVE_FILE=""
  for f in "$TASKS_DIR"/*.json; do
    [ -f "$f" ] || continue
    if python3 -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get('isActive') else 1)" "$f" 2>/dev/null; then
      ACTIVE_FILE="$f"; break
    fi
  done
fi

if [ -z "$ACTIVE_FILE" ]; then
  log "${RED}✗ No active task group found in $TASKS_DIR${NC}"
  log "${DIM}  Create tasks in Claude Todo app first.${NC}"
  echo ""; read -p "Press Enter to close..."
  exit 0
fi

GROUP_TITLE=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['title'])" "$ACTIVE_FILE")
GROUP_ID=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['id'])" "$ACTIVE_FILE")
GROUP_DATE=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('date','undated'))" "$ACTIVE_FILE")

RESOLVE_SCRIPT="$HOME/claude-auto/resolve-context.py"
REGISTRY_FILE="$HOME/claude-auto/repo-registry.json"

# Resolve repo context if task file has a "repos" field
REPO_IDS=$(python3 -c "import json,sys; print(' '.join(json.load(open(sys.argv[1])).get('repos',[])))" "$ACTIVE_FILE" 2>/dev/null || echo "")
REPO_CONTEXT=""
ADD_DIR_FLAGS=""
if [ -n "$REPO_IDS" ] && [ -f "$REGISTRY_FILE" ]; then
  REPO_CONTEXT=$(python3 "$RESOLVE_SCRIPT" "$ACTIVE_FILE" --context 2>/dev/null || echo "")
  ADD_DIR_FLAGS=$(python3 -c "
import json,os,sys
reg=json.load(open(sys.argv[1]))['repos']
ids=sys.argv[2].split()
dirs=[]
for rid in ids:
    r=reg.get(rid,{})
    p=r.get('path','')
    if p: dirs.append(os.path.expanduser(p))
print(' '.join(['--add-dir '+d for d in dirs]))
" "$REGISTRY_FILE" "$REPO_IDS" 2>/dev/null || echo "")
fi

log "${BOLD}Group:${NC}   $GROUP_TITLE"
log "${BOLD}Model:${NC}   $MODEL"
log "${BOLD}Session:${NC} #$SESSION_ID ($SESSION_NAME)"
log "${BOLD}File:${NC}    $ACTIVE_FILE"
if [ -n "$REPO_IDS" ]; then
  log "${BOLD}Repos:${NC}   $REPO_IDS"
fi
echo ""

# === Helper: Update task field in JSON ===
update_task() {
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
" "$ACTIVE_FILE" "$1" "$2" "$3"
}

# === Helper: Append an iteration entry to a task's iterations array ===
# Usage: append_iteration TASK_ID '{"json":"object"}'
append_iteration() {
  python3 -c "
import json, sys
with open(sys.argv[1], 'r') as f: data = json.load(f)
for t in data['tasks']:
    if t['id'] == sys.argv[2]:
        if 'iterations' not in t: t['iterations'] = []
        t['iterations'].append(json.loads(sys.argv[3]))
        break
with open(sys.argv[1], 'w') as f: json.dump(data, f, indent=2)
" "$ACTIVE_FILE" "$1" "$2"
}

# === Helper: Extract output summary + tool trace from a raw stream-json log ===
extract_trace() {
  python3 -c "
import json, sys
log_path = sys.argv[1]
lines = []
try:
    with open(log_path) as f: lines = f.readlines()
except: pass

texts, tools, errors = [], [], []
for line in lines:
    try:
        ev = json.loads(line.strip())
        if ev.get('type') == 'assistant':
            for b in ev.get('message',{}).get('content',[]):
                if b.get('type') == 'text':
                    texts.append(b['text'])
                elif b.get('type') == 'tool_use':
                    name = b.get('name','')
                    inp = b.get('input',{})
                    if name == 'Bash':
                        tools.append({'tool':'Bash','cmd':inp.get('command','')[:200]})
                    elif name in ('Read','Write','Edit'):
                        tools.append({'tool':name,'file':inp.get('file_path','')})
                    elif name == 'Grep':
                        tools.append({'tool':'Grep','pattern':inp.get('pattern',''),'path':inp.get('path','')})
                    else:
                        tools.append({'tool':name})
        if ev.get('type') == 'result':
            if ev.get('subtype') == 'error':
                errors.append(ev.get('error','unknown error'))
    except: pass

output = ' '.join(texts)
if len(output) > 1500: output = output[:1500] + '...'

result = {'output': output, 'tools': tools[:30], 'errors': errors}
print(json.dumps(result))
" "$1"
}

# === Collect pending tasks ===
TASK_IDS=$(python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
for t in data['tasks']:
    if t['status'] in ('pending', 'failed'):
        print(t['id'])
" "$ACTIVE_FILE")

if [ -z "$TASK_IDS" ]; then
  log "${GREEN}✓ All tasks already complete!${NC}"
  echo ""; read -p "Press Enter to close..."
  exit 0
fi

TASK_COUNT=$(echo "$TASK_IDS" | wc -l | tr -d ' ')
log "${BOLD}Tasks:${NC}   $TASK_COUNT pending"
echo ""

# === Generate a session UUID for this execution run ===
CLAUDE_SESSION_ID=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
log "${DIM}Claude Session ID: $CLAUDE_SESSION_ID${NC}"
echo ""

# === Process each task ===
TASK_NUM=0
PASSED_COUNT=0
FAILED_COUNT=0

for TASK_ID in $TASK_IDS; do
  TASK_NUM=$((TASK_NUM + 1))

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

  TASK_SCHED_DATE=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('scheduledDate',''))")
  TASK_SCHED_TIME=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('scheduledTime',''))")

  SAFE_TITLE=$(echo "$TASK_TITLE" | tr ' /' '-_' | tr -cd '[:alnum:]-_')
  RAW_LOG="$RAW_LOG_DIR/${TIMESTAMP}_S${SESSION_ID}_${TASK_NUM}_${SAFE_TITLE}.jsonl"
  DEBUG_LOG="$RAW_LOG_DIR/${TIMESTAMP}_S${SESSION_ID}_${TASK_NUM}_${SAFE_TITLE}_debug.txt"

  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  log "${BOLD}Task $TASK_NUM/$TASK_COUNT: $TASK_TITLE${NC}"
  echo -e "${DIM}ID: $TASK_ID | Model: $MODEL${NC}"

  # === Wait for scheduled time ===
  if [ -n "$TASK_SCHED_TIME" ] && [ "$TASK_SCHED_TIME" != "null" ]; then
    SCHED_TODAY="${TASK_SCHED_DATE:-$(date +%Y-%m-%d)}"
    SCHED_EPOCH=$(date -j -f "%Y-%m-%d %H:%M" "$SCHED_TODAY $TASK_SCHED_TIME" "+%s" 2>/dev/null || echo 0)
    NOW_EPOCH=$(date "+%s")
    WAIT_SECS=$((SCHED_EPOCH - NOW_EPOCH))

    if [ "$WAIT_SECS" -gt 0 ]; then
      WAIT_MINS=$((WAIT_SECS / 60))
      WAIT_REM=$((WAIT_SECS % 60))
      log "${YELLOW}⏳ Scheduled for $TASK_SCHED_TIME — waiting ${WAIT_MINS}m ${WAIT_REM}s...${NC}"
      while [ "$(date '+%s')" -lt "$SCHED_EPOCH" ]; do
        REMAINING=$(( SCHED_EPOCH - $(date '+%s') ))
        if [ "$REMAINING" -le 0 ]; then break; fi
        printf "\r  ${DIM}Starting in %dm %ds...${NC}  " $((REMAINING/60)) $((REMAINING%60))
        sleep 5
      done
      printf "\r                                    \r"
      log "${GREEN}⏰ Time reached — starting now${NC}"
    else
      log "${DIM}Scheduled time already passed — running immediately${NC}"
    fi
  fi
  echo ""

  # Update status
  update_task "$TASK_ID" "status" '"running"'
  update_task "$TASK_ID" "logs.startedAt" "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
  update_task "$TASK_ID" "logs.sessionId" "\"$CLAUDE_SESSION_ID\""

  # === Inject repo context into prompt ===
  FULL_PROMPT="$TASK_PROMPT"
  if [ -n "$REPO_CONTEXT" ] && [ "$TASK_NUM" -eq 1 ]; then
    # Only inject context into the first task (session retains it for subsequent tasks)
    FULL_PROMPT="${REPO_CONTEXT}
---

${TASK_PROMPT}"
  fi

  # === Execute task in the SAME Claude session ===
  log "${YELLOW}▸ Executing...${NC}"
  echo ""

  TASK_EXIT=0
  if [ "$TASK_NUM" -eq 1 ]; then
    # First task: start new session with --session-id (+ --add-dir for repo access)
    eval "$CLAUDE_BIN" \
      --print \
      --dangerously-skip-permissions \
      --model "$MODEL" \
      --session-id "$CLAUDE_SESSION_ID" \
      --output-format stream-json \
      --include-partial-messages \
      --verbose \
      --debug-file "$DEBUG_LOG" \
      --max-budget-usd "$MAX_BUDGET" \
      $ADD_DIR_FLAGS \
      '"$FULL_PROMPT"' \
      '>' "$RAW_LOG" '2>&1' || TASK_EXIT=$?
  else
    # Subsequent tasks: resume the same session
    "$CLAUDE_BIN" \
      --print \
      --dangerously-skip-permissions \
      --model "$MODEL" \
      --resume "$CLAUDE_SESSION_ID" \
      --output-format stream-json \
      --include-partial-messages \
      --verbose \
      --debug-file "$DEBUG_LOG" \
      --max-budget-usd "$MAX_BUDGET" \
      "$TASK_PROMPT" \
      > "$RAW_LOG" 2>&1 || TASK_EXIT=$?
  fi

  # === Extract trace from execution ===
  echo ""
  TRACE_JSON=$(extract_trace "$RAW_LOG" 2>/dev/null || echo '{"output":"","tools":[],"errors":[]}')
  SUMMARY=$(echo "$TRACE_JSON" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());o=d.get('output','');print(o[:500]+'...' if len(o)>500 else o if o else '(no output)')" 2>/dev/null || echo "(parse error)")

  echo -e "${DIM}Output: $SUMMARY${NC}"
  echo ""
  log "  Exit code: $TASK_EXIT"

  # Record iteration #1
  ITER_NUM=1
  ITER_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  ITER_ENTRY=$(python3 -c "
import json,sys
trace=json.loads(sys.argv[1])
entry={
  'iteration': int(sys.argv[2]),
  'timestamp': sys.argv[3],
  'type': 'execution',
  'exitCode': int(sys.argv[4]),
  'model': sys.argv[5],
  'logFile': sys.argv[6],
  'output': trace.get('output','')[:2000],
  'tools': trace.get('tools',[])[:30],
  'errors': trace.get('errors',[]),
  'summary': sys.argv[7][:500]
}
print(json.dumps(entry))
" "$TRACE_JSON" "$ITER_NUM" "$ITER_TIMESTAMP" "$TASK_EXIT" "$MODEL" "$RAW_LOG" "$SUMMARY" 2>/dev/null || echo '{}')
  append_iteration "$TASK_ID" "$ITER_ENTRY"

  # === Verification ===
  if [ -n "$TASK_VERIFY" ] && [ "$TASK_VERIFY" != "null" ] && [ "$TASK_VERIFY" != "" ]; then
    update_task "$TASK_ID" "status" '"verifying"'
    log "${YELLOW}▸ Verifying...${NC}"

    VERIFY_PROMPT="Verify this task was completed: $TASK_TITLE
Verification: $TASK_VERIFY
Expected result: $TASK_EXPECTED
Respond ONLY with JSON: {\"passed\": true/false, \"reason\": \"...\"}"

    VERIFY_RESULT=$("$CLAUDE_BIN" \
      --print --dangerously-skip-permissions --model "$MODEL" \
      --resume "$CLAUDE_SESSION_ID" "$VERIFY_PROMPT" 2>&1) || true

    PASSED=$(echo "$VERIFY_RESULT" | python3 -c "
import json,sys,re; text=sys.stdin.read()
m=re.search(r'\{.*\"passed\".*\}',text,re.DOTALL)
if m:
    try: print('true' if json.loads(m.group()).get('passed') else 'false')
    except: print('false')
else: print('false')
" 2>/dev/null || echo "false")

    REASON=$(echo "$VERIFY_RESULT" | python3 -c "
import json,sys,re; text=sys.stdin.read()
m=re.search(r'\{.*\"passed\".*\}',text,re.DOTALL)
if m:
    try: print(json.loads(m.group()).get('reason',''))
    except: print('parse error')
else: print('no json')
" 2>/dev/null || echo "unknown")

    # Record verification iteration
    ITER_NUM=$((ITER_NUM + 1))
    V_ENTRY=$(python3 -c "
import json,sys
entry={'iteration':int(sys.argv[1]),'timestamp':sys.argv[2],'type':'verification','passed':sys.argv[3]=='true','reason':sys.argv[4],'model':sys.argv[5]}
print(json.dumps(entry))
" "$ITER_NUM" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PASSED" "$REASON" "$MODEL" 2>/dev/null || echo '{}')
    append_iteration "$TASK_ID" "$V_ENTRY"

    if [ "$PASSED" = "true" ]; then
      update_task "$TASK_ID" "status" '"done"'
      update_task "$TASK_ID" "logs.completedAt" "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
      log "${GREEN}  ✓ PASSED${NC} — $REASON"
      PASSED_COUNT=$((PASSED_COUNT + 1))
    else
      # Retry once
      if [ "$RETRY_COUNT" -lt 1 ]; then
        log "${YELLOW}  ✗ Failed — retrying...${NC} ($REASON)"
        update_task "$TASK_ID" "retryCount" "1"
        update_task "$TASK_ID" "status" '"running"'

        RETRY_LOG="${RAW_LOG%.jsonl}_retry.jsonl"

        "$CLAUDE_BIN" \
          --print --dangerously-skip-permissions --model "$MODEL" \
          --resume "$CLAUDE_SESSION_ID" \
          --output-format stream-json --include-partial-messages --verbose \
          --debug-file "${DEBUG_LOG%.txt}_retry.txt" \
          --max-budget-usd "$MAX_BUDGET" \
          "The previous task failed verification. Reason: $REASON. Expected: $TASK_EXPECTED. Please fix: $TASK_PROMPT" \
          > "$RETRY_LOG" 2>&1 || true

        # Record retry iteration
        ITER_NUM=$((ITER_NUM + 1))
        RETRY_TRACE=$(extract_trace "$RETRY_LOG" 2>/dev/null || echo '{"output":"","tools":[],"errors":[]}')
        RETRY_SUMMARY=$(echo "$RETRY_TRACE" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());o=d.get('output','');print(o[:500]+'...' if len(o)>500 else o if o else '(no output)')" 2>/dev/null || echo "")
        R_ENTRY=$(python3 -c "
import json,sys
trace=json.loads(sys.argv[1])
entry={'iteration':int(sys.argv[2]),'timestamp':sys.argv[3],'type':'retry','model':sys.argv[4],'logFile':sys.argv[5],
'output':trace.get('output','')[:2000],'tools':trace.get('tools',[])[:30],'errors':trace.get('errors',[]),'reason':sys.argv[6],'summary':sys.argv[7][:500]}
print(json.dumps(entry))
" "$RETRY_TRACE" "$ITER_NUM" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MODEL" "$RETRY_LOG" "$REASON" "$RETRY_SUMMARY" 2>/dev/null || echo '{}')
        append_iteration "$TASK_ID" "$R_ENTRY"

        # Re-verify
        update_task "$TASK_ID" "status" '"verifying"'
        V2=$("$CLAUDE_BIN" --print --dangerously-skip-permissions --model "$MODEL" \
          --resume "$CLAUDE_SESSION_ID" "$VERIFY_PROMPT" 2>&1) || true
        P2=$(echo "$V2" | python3 -c "
import json,sys,re; text=sys.stdin.read()
m=re.search(r'\{.*\"passed\".*\}',text,re.DOTALL)
if m:
    try: print('true' if json.loads(m.group()).get('passed') else 'false')
    except: print('false')
else: print('false')
" 2>/dev/null || echo "false")
        R2=$(echo "$V2" | python3 -c "
import json,sys,re; text=sys.stdin.read()
m=re.search(r'\{.*\"passed\".*\}',text,re.DOTALL)
if m:
    try: print(json.loads(m.group()).get('reason',''))
    except: print('')
else: print('')
" 2>/dev/null || echo "")

        ITER_NUM=$((ITER_NUM + 1))
        V2_ENTRY=$(python3 -c "
import json,sys
entry={'iteration':int(sys.argv[1]),'timestamp':sys.argv[2],'type':'verification','passed':sys.argv[3]=='true','reason':sys.argv[4],'model':sys.argv[5]}
print(json.dumps(entry))
" "$ITER_NUM" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$P2" "$R2" "$MODEL" 2>/dev/null || echo '{}')
        append_iteration "$TASK_ID" "$V2_ENTRY"

        if [ "$P2" = "true" ]; then
          update_task "$TASK_ID" "status" '"done"'
          log "${GREEN}  ✓ PASSED on retry${NC}"
          PASSED_COUNT=$((PASSED_COUNT + 1))
        else
          update_task "$TASK_ID" "status" '"needs-review"'
          log "${RED}  ✗ FAILED after retry — needs review${NC}"
          FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
      else
        update_task "$TASK_ID" "status" '"needs-review"'
        log "${RED}  ✗ FAILED — already retried${NC}"
        FAILED_COUNT=$((FAILED_COUNT + 1))
      fi
      update_task "$TASK_ID" "logs.completedAt" "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
    fi
  else
    # No verification — mark done if exit 0
    if [ "$TASK_EXIT" -eq 0 ]; then
      update_task "$TASK_ID" "status" '"done"'
      PASSED_COUNT=$((PASSED_COUNT + 1))
    else
      update_task "$TASK_ID" "status" '"needs-review"'
      FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    update_task "$TASK_ID" "logs.completedAt" "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
    log "  Done (no verification step)"
  fi

  # === Parse log to Obsidian ===
  python3 "$PARSE_SCRIPT" \
    --raw-log "$RAW_LOG" --debug-log "$DEBUG_LOG" \
    --task-title "$TASK_TITLE" --group-title "$GROUP_TITLE" \
    --group-date "$GROUP_DATE" --session-num "$TASK_NUM" \
    --obsidian-dir "$OBSIDIAN_DIR" 2>/dev/null || true

  echo ""
done

# === Summary ===
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
log "${BOLD}Execution Complete${NC}"
log "  ${GREEN}Passed:${NC} $PASSED_COUNT  ${RED}Failed:${NC} $FAILED_COUNT  ${DIM}Total: $TASK_COUNT${NC}"
echo ""

# === Google Drive sync ===
if command -v rclone &>/dev/null && rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}:"; then
  log "${DIM}Syncing logs to Google Drive...${NC}"
  rclone copy "$OBSIDIAN_DIR" "${RCLONE_REMOTE}:${RCLONE_DEST}/" --update 2>/dev/null || true
  log "${DIM}Drive sync done.${NC}"
fi

# === macOS notification ===
osascript -e "display notification \"$PASSED_COUNT passed, $FAILED_COUNT failed for: $GROUP_TITLE\" with title \"Claude Todo\" sound name \"Glass\"" 2>/dev/null || true

echo ""
log "${DIM}Logs: $MASTER_LOG${NC}"
log "${DIM}Obsidian: $OBSIDIAN_DIR/${GROUP_DATE}/${NC}"
echo ""
read -p "Press Enter to close this terminal..."
