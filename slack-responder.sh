#!/bin/bash
set -euo pipefail

# ============================================================
# Slack Responder for Claude UAT
# Called by shared-dispatcher after a batch with slackContext completes.
# Posts the response as a thread reply to the original Slack message.
#
# Usage: slack-responder.sh <response-file> <batch-json-file>
# ============================================================

CLAUDE_BIN="$HOME/.local/bin/claude"
RESPONSE_FILE="$1"
BATCH_FILE="$2"

LOG="$HOME/claude-auto/logs/slack_responder_$(date +%Y%m%d_%H%M%S).log"
log() { echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG"; }

# === Extract Slack context from batch ===
SLACK_CONTEXT=$(python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
ctx = data.get('slackContext', {})
if ctx.get('channelId') and ctx.get('threadTs'):
    print(json.dumps(ctx))
else:
    print('null')
" "$BATCH_FILE" 2>/dev/null || echo "null")

if [ "$SLACK_CONTEXT" = "null" ]; then
  log "No slackContext in batch — skipping Slack reply"
  exit 0
fi

CHANNEL_ID=$(echo "$SLACK_CONTEXT" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['channelId'])")
THREAD_TS=$(echo "$SLACK_CONTEXT" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['threadTs'])")
AUTHOR=$(echo "$SLACK_CONTEXT" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('user',''))")

log "Posting reply to channel=$CHANNEL_ID thread=$THREAD_TS"

# === Read the response file and format for Slack ===
RESPONSE_CONTENT=$(python3 -c "
import sys

with open(sys.argv[1]) as f:
    content = f.read()

# Trim to Slack's 4000 char limit (leave room for header/footer)
if len(content) > 3500:
    content = content[:3500] + '\n\n... _(response truncated — full output in GitHub)_'

# Escape any problematic characters for shell
print(content)
" "$RESPONSE_FILE" 2>/dev/null || echo "Response generated but could not be read.")

BATCH_DESC=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('description','Task'))" "$BATCH_FILE" 2>/dev/null || echo "Task")

# === Post to Slack via Claude + MCP ===
"$CLAUDE_BIN" \
  --print \
  --dangerously-skip-permissions \
  --model haiku \
  --max-budget-usd 0.30 \
  "Use the slack_send_message tool to post a thread reply.

Channel ID: ${CHANNEL_ID}
Thread timestamp (thread_ts): ${THREAD_TS}

Post this EXACT message (do not modify it, do not add anything):

---
*Claude UAT — Response*

${RESPONSE_CONTENT}

---
_Executed by Claude Todo Dispatcher_
---

IMPORTANT: Use slack_send_message with channel_id='${CHANNEL_ID}' and thread_ts='${THREAD_TS}'. Do NOT reply_broadcast. Post the message exactly as shown above." \
  >> "$LOG" 2>&1 || log "Warning: Slack reply failed"

log "Reply posted"
