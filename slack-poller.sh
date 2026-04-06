#!/bin/bash
set -euo pipefail

# ============================================================
# Slack Poller for Claude UAT
# Searches Slack for @Claude-uat mentions every 3 minutes.
# Creates task JSONs and pushes to shared-Claude-Todo.
# Posts responses as thread replies when tasks complete.
# ============================================================

CLAUDE_BIN="$HOME/.local/bin/claude"
SHARED_REPO_DIR="$HOME/claude-auto/shared-repo"
SHARED_REPO_URL="https://github.com/Ayush-Puri/shared-Claude-Todo.git"
STATE_FILE="$HOME/claude-auto/.slack-poller-state.json"
LOCK_FILE="$HOME/claude-auto/.slack-poller.lock"
TRIGGER_TAG="Claude-uat"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG="$HOME/claude-auto/logs/slack_poller_${TIMESTAMP}.log"

log() { echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG"; }

# === Prevent concurrent pollers ===
if [ -f "$LOCK_FILE" ]; then
  LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    exit 0
  fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# === Initialize state file (tracks last processed timestamp) ===
if [ ! -f "$STATE_FILE" ]; then
  # Start from 5 minutes ago
  FIVE_MIN_AGO=$(python3 -c "import time; print(str(time.time() - 300))")
  echo "{\"lastProcessedTs\": \"$FIVE_MIN_AGO\", \"processedMessages\": []}" > "$STATE_FILE"
fi

LAST_TS=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('lastProcessedTs', '0'))")

log "=== Slack Poller ==="
log "Searching for @${TRIGGER_TAG} mentions since ts=$LAST_TS"

# === Search Slack for @Claude-uat mentions ===
# Use Claude to search and parse Slack messages via MCP tools
SEARCH_RESULT=$("$CLAUDE_BIN" \
  --print \
  --dangerously-skip-permissions \
  --model haiku \
  --max-budget-usd 0.50 \
  "You have access to Slack MCP tools. Do the following:

1. Use slack_search_public to search for messages containing '${TRIGGER_TAG}' from the last 5 minutes.
   Search query: '${TRIGGER_TAG}'

2. For each message found:
   - Extract the channel_id and message timestamp (ts)
   - Extract the full message text (the part AFTER '${TRIGGER_TAG}')
   - Extract the user who sent it (their display name)

3. Respond with ONLY a JSON array. No explanation, no markdown, just the JSON:
   [
     {
       \"channel_id\": \"C...\",
       \"ts\": \"1234567890.123456\",
       \"user\": \"display name\",
       \"text\": \"the request text after the trigger tag\"
     }
   ]

   If no messages found, respond with: []

IMPORTANT: Only include messages with timestamp > ${LAST_TS}
IMPORTANT: Respond with ONLY the JSON array, nothing else." 2>&1) || true

log "Search result: $(echo "$SEARCH_RESULT" | head -5)"

# === Parse the search results ===
MESSAGES=$(echo "$SEARCH_RESULT" | python3 -c "
import json, sys, re

text = sys.stdin.read()
# Find JSON array in the response
match = re.search(r'\[.*\]', text, re.DOTALL)
if match:
    try:
        msgs = json.loads(match.group())
        if isinstance(msgs, list):
            print(json.dumps(msgs))
        else:
            print('[]')
    except:
        print('[]')
else:
    print('[]')
" 2>/dev/null || echo "[]")

MSG_COUNT=$(echo "$MESSAGES" | python3 -c "import json,sys; print(len(json.loads(sys.stdin.read())))")
log "Found $MSG_COUNT new message(s)"

if [ "$MSG_COUNT" -eq "0" ]; then
  log "No new mentions. Done."
  exit 0
fi

# === Clone/update shared repo ===
if [ -d "$SHARED_REPO_DIR/.git" ]; then
  cd "$SHARED_REPO_DIR" && git fetch origin 2>/dev/null && git reset --hard origin/main 2>/dev/null && cd - >/dev/null
else
  rm -rf "$SHARED_REPO_DIR"
  git clone "$SHARED_REPO_URL" "$SHARED_REPO_DIR" 2>/dev/null
fi

# === Process each message into a task ===
echo "$MESSAGES" | python3 -c "
import json, sys, os, re

messages = json.loads(sys.stdin.read())
shared_dir = os.path.expanduser('~/claude-auto/shared-repo')
state_file = os.path.expanduser('~/claude-auto/.slack-poller-state.json')

# Load state
with open(state_file) as f:
    state = json.load(f)
processed = set(state.get('processedMessages', []))

new_ts = state.get('lastProcessedTs', '0')

for msg in messages:
    ts = msg.get('ts', '')
    if ts in processed:
        continue

    channel_id = msg.get('channel_id', '')
    user = msg.get('user', 'unknown')
    text = msg.get('text', '').strip()

    if not text or not channel_id:
        continue

    # Generate batch slug
    slug = re.sub(r'[^a-z0-9]+', '-', text.lower())[:40].strip('-')
    if not slug:
        slug = f'slack-task-{ts}'

    # Create task JSON
    task = {
        'batch': f'slack-{slug}',
        'description': text,
        'author': user,
        'priority': 50,
        'model': 'sonnet',
        'pipeline': 'research',
        'repos': [],
        'goal': text,
        'slackContext': {
            'channelId': channel_id,
            'threadTs': ts,
            'user': user
        },
        'tasks': [
            {
                'title': f'Process request from {user}',
                'prompt': text,
                'verification': '',
                'expectedResult': ''
            }
        ]
    }

    # Write to queue/
    filename = f'50-slack-{slug}.json'
    filepath = os.path.join(shared_dir, 'queue', filename)
    with open(filepath, 'w') as f:
        json.dump(task, f, indent=2)
    print(f'Created: {filename}')

    processed.add(ts)
    if ts > new_ts:
        new_ts = ts

# Update state
# Keep only last 200 processed message IDs to prevent unbounded growth
processed_list = sorted(processed)[-200:]
state['lastProcessedTs'] = new_ts
state['processedMessages'] = processed_list
with open(state_file, 'w') as f:
    json.dump(state, f, indent=2)
" 2>&1 | tee -a "$LOG"

# === Push to GitHub ===
cd "$SHARED_REPO_DIR"
git add -A 2>/dev/null
if ! git diff --cached --quiet 2>/dev/null; then
  git commit -m "queue(slack): ${MSG_COUNT} task(s) from Slack @${TRIGGER_TAG} [$(date '+%H:%M')]" 2>/dev/null
  git push origin main 2>/dev/null && log "Pushed ${MSG_COUNT} task(s) to queue" || log "Warning: push failed"
fi
cd - >/dev/null

log "=== Poller complete ==="
