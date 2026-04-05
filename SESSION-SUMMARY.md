# Claude Todo — Complete Session Summary

**Date:** April 3–5, 2026
**Duration:** ~6 hours across multiple sessions
**Built by:** Ayush Puri + Claude (Haiku 4.5 → Opus 4.6)

---

## What We Built

A fully autonomous task scheduling, execution, and logging system for Claude Code — packaged as a native macOS app called **Claude Todo**. It turns Claude Code from an interactive tool into a programmable, scheduled, collaborative automation engine.

---

## Everything We Did (Chronological)

### Phase 1: Automated Nightly Runner
- Created `~/claude-auto/run.sh` — a shell script that runs Claude Code headlessly at 2 AM
- Set up a **launchd plist** (`com.claude.autorun`) as macOS's native scheduler (more reliable than cron)
- Added `com.claude.caffeinate` to prevent Mac from sleeping during runs
- Created a placeholder task file (`nightly-task.md`) for instructions

### Phase 2: Interactive Dashboard
- Built `dashboard.html` — a single-file web app for managing tasks
- Features: task groups, drag-to-reorder, token estimation, export to markdown
- Animated flowcharts and documentation page explaining the system
- Dark theme with floating orbs and gradient effects

### Phase 3: Native macOS App
- Wrote `ClaudeTaskRunner.swift` — a Swift app using WKWebView
- Compiled into a real `.app` bundle at `/Applications/Claude Todo.app`
- **Isolated localStorage** via `WKWebsiteDataStore(forIdentifier:)` — separate from Safari
- Shows in Dock, Spotlight, Cmd+Tab — a proper native app
- Full menu bar: Edit (copy/paste), View (reload), Window (fullscreen)

### Phase 4: Custom App Icon
- Generated a programmatic icon via Python (no design tools):
  - Claude's sparkle/starburst in warm terracotta (center)
  - Purple-ringed clock (top-left) representing scheduled execution
  - Yellow crescent moon with stars (top-right) representing overnight automation
  - Dark rounded-square background
- Created full iconset (16px to 1024px) and compiled to `.icns`

### Phase 5: Claude Mac App Theme Match
- Extracted exact CSS variables from Claude.app's `app.asar`:
  - `--claude-background-color: #262624`
  - `--claude-accent-clay: #d97757`
  - `--claude-text-100: #f5f4ef`
  - System font stack: `-apple-system, BlinkMacSystemFont`
- Rebuilt the entire dashboard to match Claude's dark mode shade-for-shade
- Updated Swift window background to match

### Phase 6: IDE-Style Layout with Tabs
- Redesigned dashboard with:
  - **Sidebar** (220px) — all groups listed like a file tree
  - **Tab bar** — open multiple groups as tabs simultaneously
  - **Centered title** in the toolbar
- Fixed the native titlebar for proper drag/move/resize
- Added dark Aqua appearance to the Swift window

### Phase 7: Full Automation Pipeline
- Created `~/claude-auto/tasks/*.json` — file-based task storage that Claude can read/write directly
- Created `~/claude-auto/instructions.md` — Claude's guide for populating tasks
- Rewrote `runner.sh` → `executor.sh` with:
  - **Session-aware execution** (detects which 5-hour window it's in)
  - **Model selection** per session (haiku/sonnet/opus)
  - **Auto-verification** after each task with retry logic
  - **Stream-JSON logging** for detailed output capture
- Created `parse-log.py` — converts raw logs to readable Obsidian markdown
- Created `sessions.json` — configurable 5-session-per-day schedule

### Phase 8: 5 Session Windows
Configured launchd to fire at 5 times daily:

| Session | Window | Default Model |
|---------|--------|---------------|
| 1 — Morning | 8:30 AM – 1:30 PM | haiku |
| 2 — Afternoon | 1:30 PM – 6:30 PM | haiku |
| 3 — Evening | 6:30 PM – 11:30 PM | haiku |
| 4 — Night | 11:30 PM – 4:30 AM | haiku |
| 5 — Early Morning | 4:30 AM – 8:30 AM | haiku |

### Phase 9: Obsidian + Google Drive Logging
- Installed **rclone** via Homebrew
- Configured Google Drive remote (`gdrive:`) with OAuth for `ayushpuri.work@gmail.com`
- Scoped to `drive.file` (rclone can only access files it creates)
- Logs written to `~/Documents/Obsidian/Syfe/Claude Logs/` as markdown
- Auto-synced to Google Drive folder `Claude Todo Logs/` after each session
- Each log includes: task title, session number, model, duration, token usage, tool trace, full output

### Phase 10: Native Bridge (JS ↔ Swift ↔ Filesystem)
- Added `WKScriptMessageHandler` to the Swift app
- JavaScript calls `window.webkit.messageHandlers.nativeBridge.postMessage(...)` to:
  - **saveGroup** — write task JSON directly to `~/claude-auto/tasks/`
  - **deleteGroup** — remove a task file from disk
  - **runTasks** — open Terminal and launch executor via AppleScript
- Auto-save on **focus blur** from any input field (title, prompt, verification, expected result)
- No more manual export buttons — editing the app writes to disk instantly

### Phase 11: Bidirectional File Sync
- Added `TaskFileWatcher` in Swift — polls `~/claude-auto/tasks/` every 3 seconds
- Compares file modification timestamps to detect changes
- Pushes updated data to JavaScript via `_onGroupsLoaded` callback
- Tasks completed by the executor auto-update in the app UI within 3 seconds
- Status changes (pending → running → done/failed) reflected live

### Phase 12: Terminal-Based Execution
- Created `executor.sh` — opens a visible Terminal window for execution
- Uses `--session-id` for the first task, `--resume` for subsequent tasks
- **All tasks in a group share one Claude Code session** (full context preserved)
- Colored terminal output with progress bars and summaries
- **Scheduled time wait** — each task waits for its `scheduledTime` with a live countdown
- macOS notification on completion

### Phase 13: Section-Based UI Redesign
Replaced day-based groups with IDE-style sections:

| Section | Purpose |
|---------|---------|
| **To-Do** | Active tasks ready for execution |
| **Next Week** | Tasks scheduled for next week (auto-detected by date) |
| **Projects** | Custom subsections per project (+ to create) |
| **Failed** | Tasks that failed execution |
| **Needs Review** | Tasks that failed after retry |
| **Done** | Completed and verified tasks |

- **Cmd+N** creates a new task in the current section
- **Double-click** expands a task card
- **Checkbox** is for group selection (not mark-done)
- **Bulk actions** when tasks are selected: move to any section, delete
- **Drag and drop** tasks between sidebar sections (updates status automatically)

### Phase 14: Iteration Trace History
- Every execution, verification, and retry is recorded as an **iteration** in the task's `iterations[]` array
- Each iteration captures: timestamp, type, model, exit code, output (2KB), tool trace, errors, verification reason
- Visual **timeline** in expanded task cards:
  - 🔵 Execution → 🟢 Verification passed / 🔴 Verification failed → 🟡 Retry
- "Show more/less" toggle for long output traces
- Summary line: "Last failure: ..." for quick review

### Phase 15: Shared Queue (Collaborative Execution)
- Created [**shared-Claude-Todo**](https://github.com/Ayush-Puri/shared-Claude-Todo) repo
- Collaborators push task JSON to `queue/` directory
- **Dispatcher** (`shared-dispatcher.sh`) polls every 2 minutes via launchd
- Runs **max 3 concurrent Claude Code sessions** per round
- Waits for all 3 to complete before fetching next batch
- Moves completed batches: `queue/` → `done/` or `failed/`
- Pushes status back to GitHub so collaborators see results
- Full README with task format documentation and security notes

### Phase 16: Apple Automator Greeter
- Created `Claude Haiku Greeter.app` — opens Terminal, starts Claude with Haiku model, sends "hi"
- Compiled via `osacompile` into a standalone `.app` at `~/Applications/`

### Phase 17: GitHub Integration Tests
- Successfully executed automated tasks that:
  - Created the [Claude-Todo](https://github.com/Ayush-Puri/Claude-Todo) GitHub repository
  - Pushed all source code with README
  - Created branches, committed changes, opened PRs, and merged them
  - All via scheduled, timed task execution through the pipeline

---

## File Structure

```
~/claude-auto/
├── dashboard.html              # Main UI (loaded by the native app)
├── executor.sh                 # Visible terminal executor (scheduled + manual)
├── runner.sh                   # Headless executor (legacy, still works)
├── shared-dispatcher.sh        # Shared queue dispatcher (GitHub sync)
├── parse-log.py                # Stream-JSON → Obsidian markdown converter
├── instructions.md             # Claude's guide for populating tasks
├── sessions.json               # 5 session windows configuration
├── sync-tasks.sh               # Task file listing helper
├── tasks/                      # Task JSON files (bidirectional sync with app)
│   ├── todo.json
│   ├── next-week.json
│   └── *.json
├── logs/
│   ├── raw/                    # Raw stream-json execution logs
│   ├── runner_*.log            # Executor master logs
│   ├── shared_*.log            # Shared dispatcher logs
│   └── launchd_*.log           # launchd output
├── shared-repo/                # Local clone of shared-Claude-Todo (auto-managed)
├── app/
│   ├── ClaudeTaskRunner.swift  # Native macOS app source
│   ├── build.sh                # Full installer script
│   ├── gen_icon.py             # App icon generator
│   └── AppIcon.icns            # Compiled icon

/Applications/Claude Todo.app   # The installed native app
~/Library/LaunchAgents/
├── com.claude.autorun.plist         # 5 daily session triggers
├── com.claude.caffeinate.plist      # Sleep prevention
├── com.claude.shared-dispatcher.plist  # Shared queue poll (every 2 min)

~/Documents/Obsidian/Syfe/Claude Logs/  # Markdown execution logs
Google Drive: Claude Todo Logs/          # Cloud backup of logs
```

---

## What You Can Do With It

### As a Solo User
- **Schedule coding tasks overnight**: Write tests, refactor code, generate docs — all while you sleep
- **Run 5 sessions per day**: Every token window is used productively
- **Queue tasks with precise timing**: Schedule tasks at specific times with automatic countdown
- **Review everything in the morning**: Full execution traces in Obsidian, synced to Google Drive
- **Manage tasks visually**: Native macOS app with drag-drop, sections, keyboard shortcuts

### As a Team Lead
- **Delegate tasks to Claude**: Write task files and let Claude execute them autonomously
- **Shared queue**: Team members push tasks to GitHub, your Mac executes them
- **PR-based review**: Enable branch protection so all tasks are reviewed before execution
- **Audit trail**: Full git history of who added what tasks and when
- **3 concurrent sessions**: Parallel execution with automatic round management

### For Automation
- **CI/CD integration**: Push task files from CI pipelines to the shared repo
- **Cron-like Claude jobs**: Schedule recurring tasks via the 5 session windows
- **Self-healing**: Auto-verify and retry failed tasks, with full trace history
- **Cross-project**: Create project subsections, each with their own task queues

### For Monitoring
- **Obsidian vault**: All execution logs as interlinked markdown notes
- **Google Drive sync**: Cloud backup accessible from any device
- **Iteration traces**: Linked-list history showing every attempt, tool used, and failure reason
- **Live status**: App updates within 3 seconds of task completion

---

## GitHub Repositories

| Repo | Purpose |
|------|---------|
| [Ayush-Puri/Claude-Todo](https://github.com/Ayush-Puri/Claude-Todo) | App source code, executors, build system |
| [Ayush-Puri/shared-Claude-Todo](https://github.com/Ayush-Puri/shared-Claude-Todo) | Collaborative task queue for team use |

### PRs Created During This Session
1. **#1** — Initial commit with all source files and README
2. **#2** — docs: add badges and system requirements (auto-executed by pipeline)
3. **#3** — feat: v2 — bidirectional sync, auto-installer, scheduled execution
4. **#4** — feat: add Failed and Needs Review sidebar sections
5. **#5** — feat: iteration trace history with linked-list timeline
6. **#6** — feat: shared queue dispatcher for collaborative task execution

---

## Technical Stack

| Component | Technology |
|-----------|-----------|
| Native app | Swift + WKWebView (macOS 14+) |
| Dashboard UI | Vanilla HTML/CSS/JS (single file, no frameworks) |
| Task execution | Claude Code CLI (`--print`, `--session-id`, `--resume`) |
| Scheduling | macOS launchd (5 calendar intervals) |
| Logging | Stream-JSON → Python parser → Obsidian markdown |
| Cloud sync | rclone → Google Drive (`drive.file` scope) |
| Collaboration | GitHub repo + git pull/push |
| Icon generation | Python (pure PNG generation, no PIL) |
| Sleep prevention | caffeinate daemon via launchd |

---

## Fresh Install (One Command)

```bash
git clone https://github.com/Ayush-Puri/Claude-Todo.git
cd Claude-Todo
bash app/build.sh
```

This creates everything: `~/claude-auto/` directory structure, compiles the Swift app, installs to `/Applications/`, sets up all launchd jobs, and opens the app.

---

*This document was generated at the end of the session on April 5, 2026.*
