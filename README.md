# Claude Todo

**Automated task scheduler and executor for Claude Code**

A native macOS app that schedules, manages, and auto-executes AI coding tasks across multiple session windows with full logging to Obsidian and Google Drive.

## Features

- **Native macOS App**: Swift-based WKWebView application for seamless integration
- **Task Management**: Drag-and-drop interface for organizing and prioritizing tasks
- **5 Session Windows Per Day**: Manage up to 5 concurrent Claude Code sessions
- **Auto-Verification with Retry**: Automatic task verification with intelligent retry logic
- **Obsidian Markdown Logging**: Full task execution logs exported to Obsidian
- **Google Drive Sync**: Optional automatic synchronization of logs and results
- **Claude Code CLI Integration**: Direct integration with the Claude Code command-line interface

## Architecture

Claude Todo consists of several interconnected components:

- **Swift WKWebView App**: Native macOS application providing the user interface
- **HTML/JS Dashboard**: Interactive web-based dashboard for task management
- **executor.sh**: Core orchestrator that manages task execution and coordination
- **launchd Scheduling**: System-level scheduling for automated task execution

## Installation

1. **Clone the repository**:
   ```bash
   git clone https://github.com/Ayush-Puri/Claude-Todo.git
   cd Claude-Todo
   ```

2. **Run the build script**:
   ```bash
   cd app
   ./build.sh
   cd ..
   ```

3. **Configure sessions.json**:
   Edit `sessions.json` to define your Claude Code sessions and preferences

4. **Load launchd plist**:
   ```bash
   # Copy the plist file to the appropriate location
   cp ~/claude-auto/app/com.ayush.claudetodo.plist ~/Library/LaunchAgents/
   launchctl load ~/Library/LaunchAgents/com.ayush.claudetodo.plist
   ```

## Usage

### Creating Tasks

1. Open the Claude Todo application
2. Click "New Task" in the dashboard
3. Enter task description, priority, and session assignment
4. Set execution time or schedule

### Running Tasks

1. Tasks execute automatically according to schedule
2. Manual execution: click "Run" button in the dashboard
3. View real-time execution status and logs

### Viewing Logs

- **Dashboard**: View recent task executions and results
- **Obsidian**: Access detailed markdown logs in your Obsidian vault
- **Google Drive**: Sync logs automatically (if configured)

## File Structure

```
Claude-Todo/
├── dashboard.html          # Interactive web dashboard UI
├── executor.sh            # Core task execution orchestrator
├── runner.sh              # Task runner and command executor
├── parse-log.py           # Log parser and processor
├── sync-tasks.sh          # Google Drive and Obsidian sync handler
├── instructions.md        # Detailed setup and usage instructions
├── sessions.json          # Session configuration file
├── app/
│   ├── ClaudeTaskRunner.swift    # Main Swift application code
│   ├── build.sh                  # Build script for the macOS app
│   ├── gen_icon.py              # Icon generator utility
│   └── com.ayush.claudetodo.plist # launchd configuration
└── README.md              # This file
```

## Requirements

- **macOS 14+**: Sonoma or later
- **Claude Code CLI**: Latest version installed and configured
- **Git**: For repository management
- **rclone**: Optional, for Google Drive synchronization

## License

MIT

## Support

For issues, feature requests, or contributions, please open an issue on GitHub.
