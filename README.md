# Claude Todo

Automated task scheduler and executor for Claude Code. A native macOS app that schedules, manages, and auto-executes AI coding tasks — with Slack integration, collaborative GitHub queue, and full execution logging.

[![Built with Claude Code](https://img.shields.io/badge/Built%20with-Claude%20Code-blue)](https://claude.ai/code) [![Swift](https://img.shields.io/badge/Swift-6.0+-orange)](https://swift.org) [![macOS](https://img.shields.io/badge/macOS-14+-green)](https://www.apple.com/macos) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Status:** Active development — contributions welcome

---

## What It Does

- **Schedule AI tasks overnight** — queue coding work and let Claude execute while you sleep
- **5 session windows per day** — every token window is used (8:30, 13:30, 18:30, 23:30, 4:30)
- **Collaborative queue** — team members push tasks via GitHub, Slack, or the `/claude-uat` skill
- **Auto-verify and retry** — each task is verified after execution, retried once if failed
- **Full logging** — execution traces saved to Obsidian vault and Google Drive
- **Slack integration** — mention `@Claude-uat` in any channel, get results as a thread reply

## Architecture

```
┌─────────────── TASK CREATION ────────────────┐
│  Claude Todo App  │  /claude-uat  │  Slack    │
│  (macOS native)   │  (skill)      │  @mention │
└───────┬───────────┴───────┬───────┴─────┬─────┘
        │                   │             │
        ▼                   ▼             ▼
   ~/claude-auto/      GitHub:        Slack Poller
   tasks/*.json     shared-Claude-    (every 3 min)
        │           Todo/queue/           │
        │                │                │
        ▼                ▼                ▼
┌──────────────── EXECUTION ───────────────────┐
│  executor.sh — Claude Code sessions          │
│  (--session-id + --resume for shared context)│
│  Verify → Retry (1x) → Done / Needs Review  │
└──────────────────────┬───────────────────────┘
                       │
        ┌──────────────┼──────────────┐
        ▼              ▼              ▼
   Obsidian       Google Drive    Slack Thread
   Vault          (rclone)       Reply
```

---

## Installation

### Prerequisites

- macOS 14 (Sonoma) or later
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- Xcode Command Line Tools: `xcode-select --install`
- GitHub CLI: `brew install gh && gh auth login`

### Quick Install

```bash
git clone https://github.com/Ayush-Puri/Claude-Todo.git
cd Claude-Todo
bash app/build.sh
```

This single command:
1. Creates `~/claude-auto/` with all source files and directory structure
2. Compiles the Swift app and installs to `/Applications/Claude Todo.app`
3. Generates the app icon (Claude sparkle + clock + moon)
4. Installs all 4 launchd jobs (sessions, dispatcher, Slack poller, caffeinate)
5. Opens the app

### Install launchd Jobs Only

If you already have the app and just want to set up/reset the background services:

```bash
bash launchd/install.sh    # Install all 4 jobs
bash launchd/status.sh     # Check what's running
bash launchd/uninstall.sh  # Remove all jobs
```

### Optional: Google Drive Sync

```bash
brew install rclone
rclone config create gdrive drive scope drive.file
# Browser opens → sign in with your Google account → done
```

### Optional: Slack Integration

The Slack poller is installed by default. It searches for `@Claude-uat` mentions in any Slack channel every 3 minutes. Requires Slack MCP tools in your Claude Code configuration.

### Optional: `/claude-uat` Skill

Install the Claude Code skill so any team member can queue tasks:

```bash
npx skills add git@github.com:SvavaCapital/syfe-ai-skills.git --skill claude-uat -g -y
```

Then from any repo: `/claude-uat Fix the token refresh bug`

---

## Usage

### In the App

1. Open **Claude Todo** from Applications or Spotlight
2. Create a group in the sidebar (+ New Group)
3. Add tasks — each has: title, instructions, verification, expected result, scheduled time
4. Click **Run** to execute immediately, or let the scheduler handle it
5. Tasks auto-move to Done/Failed/Needs Review sections

### Via Slack

```
@Claude-uat compare Redis vs Memcached for session caching
```
Response comes back as a thread reply within ~5 minutes.

### Via /claude-uat Skill

From any repo:
```
/claude-uat Add a health check endpoint to this service
```
The skill auto-detects the repo, decomposes into tasks, and pushes to the queue.

### Via GitHub (Direct Push)

Push a task JSON to [shared-Claude-Todo](https://github.com/Ayush-Puri/shared-Claude-Todo):
```bash
git clone https://github.com/Ayush-Puri/shared-Claude-Todo.git
# Create queue/50-my-task.json (see TASK-FORMAT.md for schema)
git add . && git commit -m "Add task" && git push
```

---

## Background Services

| Service | launchd Label | Schedule | Purpose |
|---------|--------------|----------|---------|
| **Session Executor** | `com.claude.autorun` | 8:30, 13:30, 18:30, 23:30, 4:30 | Runs local tasks from Claude Todo app |
| **Shared Dispatcher** | `com.claude.shared-dispatcher` | Every 2 min | Pulls tasks from GitHub queue, max 3 concurrent |
| **Slack Poller** | `com.claude.slack-poller` | Every 3 min | Searches Slack for @Claude-uat mentions |
| **Sleep Prevention** | `com.claude.caffeinate` | Always on | Prevents Mac from sleeping during execution |

```bash
# Check status of all services
bash launchd/status.sh

# Or manually
launchctl list | grep claude
```

---

## File Structure

```
Claude-Todo/
├── app/
│   ├── build.sh                 # Full installer (app + launchd + files)
│   ├── ClaudeTaskRunner.swift   # Native macOS app (Swift + WKWebView)
│   └── gen_icon.py              # App icon generator
├── launchd/
│   ├── com.claude.autorun.plist            # 5 daily session triggers
│   ├── com.claude.shared-dispatcher.plist  # GitHub queue poll (2 min)
│   ├── com.claude.slack-poller.plist       # Slack mention poll (3 min)
│   ├── com.claude.caffeinate.plist         # Sleep prevention
│   ├── install.sh               # Install all launchd jobs
│   ├── uninstall.sh             # Remove all launchd jobs
│   └── status.sh                # Check job status
├── dashboard.html               # Task management UI
├── executor.sh                  # Visible terminal task executor
├── runner.sh                    # Headless task executor (legacy)
├── shared-dispatcher.sh         # GitHub queue dispatcher
├── slack-poller.sh              # Slack @Claude-uat mention poller
├── slack-responder.sh           # Posts responses as Slack thread replies
├── parse-log.py                 # Stream-JSON → Obsidian markdown
├── resolve-context.py           # Repo context resolver
├── repo-registry.json           # 30+ repo catalog (paths, deps, APIs)
├── sessions.json                # 5 session window configuration
├── instructions.md              # Claude's task population guide
└── sync-tasks.sh                # Task file listing helper
```

### Runtime directories (created by installer)

```
~/claude-auto/
├── tasks/          # Task JSON files (bidirectional sync with app)
├── logs/
│   └── raw/        # Stream-JSON execution logs
├── shared-repo/    # Local clone of shared-Claude-Todo
└── .slack-poller-state.json  # Tracks processed Slack messages
```

---

## Task Pipelines

The `/claude-uat` skill and shared queue support 8 task pipelines:

| Pipeline | Pattern | Use Case |
|----------|---------|----------|
| `code-fix` | Diagnose → Fix → PR | Bug fixes |
| `code-feature` | Explore → Implement → Test → PR | New features |
| `code-refactor` | Analyze → Refactor → Verify → PR | Code cleanup |
| `code-test` | Find gaps → Write tests → PR | Test coverage |
| `code-review` | Review → Write report | Code audits |
| `research` | Research → Synthesize → Output (md/csv/pdf) | General research |
| `document` | Gather → Write → Optional PR | Documentation |
| `ops` | Check state → Apply → PR | Infrastructure |

---

## Configuration

### Session Windows (`sessions.json`)

Edit to change session times, models, or budgets:

```json
{
  "sessions": [
    { "id": 1, "name": "Morning", "startHour": 8, "startMinute": 30, "endHour": 13, "endMinute": 30, "model": "haiku" },
    { "id": 2, "name": "Afternoon", "startHour": 13, "startMinute": 30, "endHour": 18, "endMinute": 30, "model": "haiku" }
  ]
}
```

### Repo Registry (`repo-registry.json`)

Add your repos so the context resolver can auto-inject metadata:

```json
{
  "repos": {
    "my-service": {
      "name": "my-service",
      "path": "~/projects/my-service",
      "description": "My backend service",
      "tech": ["Node.js", "PostgreSQL"],
      "dependsOn": ["shared-db"],
      "dependedBy": ["api-gateway"]
    }
  }
}
```

---

## Requirements

| Component | Required | Optional |
|-----------|----------|----------|
| macOS 14+ | Yes | |
| Claude Code CLI | Yes | |
| Xcode CLI Tools | Yes (for Swift compilation) | |
| GitHub CLI (`gh`) | Yes (for shared queue + PRs) | |
| rclone | | Google Drive log sync |
| Slack MCP tools | | Slack @Claude-uat integration |

---

## Related Repos

| Repo | Purpose |
|------|---------|
| [Ayush-Puri/Claude-Todo](https://github.com/Ayush-Puri/Claude-Todo) | This repo — app, executors, all scripts |
| [Ayush-Puri/shared-Claude-Todo](https://github.com/Ayush-Puri/shared-Claude-Todo) | Collaborative task queue |

---

## License

MIT — see [LICENSE](LICENSE)
