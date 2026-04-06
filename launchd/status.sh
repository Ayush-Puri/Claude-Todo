#!/bin/bash

# ============================================================
# Claude Todo — Check Status of All launchd Jobs
# ============================================================

echo "Claude Todo — launchd Job Status"
echo "================================"
echo ""

JOBS=(
  "com.claude.autorun|Session Executor|8:30 13:30 18:30 23:30 4:30"
  "com.claude.shared-dispatcher|Shared Dispatcher|every 2 min"
  "com.claude.slack-poller|Slack Poller|every 3 min"
  "com.claude.caffeinate|Sleep Prevention|always on"
)

for JOB in "${JOBS[@]}"; do
  IFS='|' read -r LABEL NAME SCHEDULE <<< "$JOB"
  STATUS=$(launchctl list 2>/dev/null | grep "$LABEL" || echo "")

  if [ -n "$STATUS" ]; then
    PID=$(echo "$STATUS" | awk '{print $1}')
    EXIT=$(echo "$STATUS" | awk '{print $2}')
    if [ "$PID" = "-" ]; then
      echo "  ✓ $NAME ($SCHEDULE) — loaded, last exit: $EXIT"
    else
      echo "  ● $NAME ($SCHEDULE) — running (PID $PID)"
    fi
  else
    echo "  ✗ $NAME — not loaded"
  fi
done

echo ""
echo "Recent logs:"
ls -lt ~/claude-auto/logs/*.log 2>/dev/null | head -5 | awk '{print "  " $6, $7, $8, $9}'
