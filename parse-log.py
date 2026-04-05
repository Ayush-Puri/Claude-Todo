#!/usr/bin/env python3
"""Parse Claude Code stream-json logs into readable Obsidian markdown."""

import json
import os
import sys
import argparse
from datetime import datetime
from pathlib import Path


def parse_stream_json(raw_log_path):
    """Parse a stream-json log file into structured data."""
    events = []
    if not os.path.exists(raw_log_path):
        return events
    with open(raw_log_path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return events


def extract_session_info(events):
    """Extract session metadata from events."""
    info = {
        'session_id': None,
        'model': None,
        'start_time': None,
        'total_input_tokens': 0,
        'total_output_tokens': 0,
        'cost_usd': 0,
        'duration_seconds': 0,
    }
    for ev in events:
        if ev.get('type') == 'system' and ev.get('subtype') == 'init':
            info['session_id'] = ev.get('session_id')
            info['model'] = ev.get('model')
        if ev.get('type') == 'result':
            info['duration_seconds'] = ev.get('duration_seconds', 0)
            info['cost_usd'] = ev.get('cost_usd', 0)
            usage = ev.get('usage', {})
            info['total_input_tokens'] = usage.get('input_tokens', 0)
            info['total_output_tokens'] = usage.get('output_tokens', 0)
    return info


def extract_actions(events):
    """Extract tool uses and assistant messages."""
    actions = []
    for ev in events:
        if ev.get('type') == 'assistant':
            msg = ev.get('message', {})
            content_blocks = msg.get('content', [])
            for block in content_blocks:
                if block.get('type') == 'text':
                    actions.append({
                        'type': 'text',
                        'content': block.get('text', '')
                    })
                elif block.get('type') == 'tool_use':
                    actions.append({
                        'type': 'tool_use',
                        'tool': block.get('name', 'Unknown'),
                        'input': block.get('input', {})
                    })
                elif block.get('type') == 'thinking':
                    actions.append({
                        'type': 'thinking',
                        'content': block.get('thinking', '')
                    })
    return actions


def format_tool_action(action):
    """Format a tool use action for markdown."""
    tool = action['tool']
    inp = action.get('input', {})

    if tool == 'Read':
        return f"**Read** `{inp.get('file_path', '?')}`"
    elif tool == 'Write':
        return f"**Write** `{inp.get('file_path', '?')}`"
    elif tool == 'Edit':
        return f"**Edit** `{inp.get('file_path', '?')}`"
    elif tool == 'Bash':
        cmd = inp.get('command', '?')
        if len(cmd) > 80:
            cmd = cmd[:80] + '...'
        return f"**Bash** `{cmd}`"
    elif tool == 'Grep':
        return f"**Grep** pattern=`{inp.get('pattern', '?')}` in `{inp.get('path', '.')}`"
    elif tool == 'Glob':
        return f"**Glob** `{inp.get('pattern', '?')}`"
    else:
        return f"**{tool}** {json.dumps(inp)[:100]}"


def generate_markdown(task_title, group_title, session_num, session_info, actions, debug_log_path):
    """Generate the Obsidian markdown file content."""
    now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    duration = session_info.get('duration_seconds', 0)
    dur_str = f"{int(duration // 60)}m {int(duration % 60)}s" if duration else "Unknown"
    cost = session_info.get('cost_usd', 0)
    input_tok = session_info.get('total_input_tokens', 0)
    output_tok = session_info.get('total_output_tokens', 0)

    lines = []
    lines.append(f"# {task_title}")
    lines.append(f"")
    lines.append(f"## Session #{session_num} — {now}")
    lines.append(f"")
    lines.append(f"**Group:** {group_title}")
    lines.append(f"**Model:** {session_info.get('model', 'Unknown')}")
    lines.append(f"**Duration:** {dur_str}")
    lines.append(f"**Tokens:** {input_tok:,} in / {output_tok:,} out ({input_tok + output_tok:,} total)")
    if cost:
        lines.append(f"**Cost:** ${cost:.4f}")
    lines.append(f"")

    # Thinking sections
    thinking_blocks = [a for a in actions if a['type'] == 'thinking']
    if thinking_blocks:
        lines.append(f"## Thinking")
        lines.append(f"")
        for i, tb in enumerate(thinking_blocks):
            content = tb['content']
            if len(content) > 2000:
                content = content[:2000] + '\n\n... (truncated)'
            lines.append(f"### Thinking Block {i + 1}")
            lines.append(f"")
            lines.append(f"```")
            lines.append(content)
            lines.append(f"```")
            lines.append(f"")

    # Actions / Tool Use
    tool_actions = [a for a in actions if a['type'] == 'tool_use']
    if tool_actions:
        lines.append(f"## Actions")
        lines.append(f"")
        for i, action in enumerate(tool_actions):
            lines.append(f"{i + 1}. {format_tool_action(action)}")
        lines.append(f"")

    # Full text output
    text_blocks = [a for a in actions if a['type'] == 'text']
    if text_blocks:
        lines.append(f"## Full Output")
        lines.append(f"")
        for tb in text_blocks:
            content = tb['content']
            if len(content) > 5000:
                content = content[:5000] + '\n\n... (truncated to 5000 chars)'
            lines.append(content)
            lines.append(f"")

    # Debug log reference
    if debug_log_path and os.path.exists(debug_log_path):
        lines.append(f"## Debug Log")
        lines.append(f"")
        lines.append(f"Full debug log: `{debug_log_path}`")
        lines.append(f"")

    lines.append(f"---")
    lines.append(f"*Generated by Claude Todo Runner at {now}*")

    return '\n'.join(lines)


def update_index(obsidian_dir, group_title, group_date, session_num, task_title, md_filename, md_relpath):
    """Append entry to index.md."""
    index_path = os.path.join(obsidian_dir, 'index.md')
    now = datetime.now().strftime('%Y-%m-%d %H:%M')

    if not os.path.exists(index_path):
        with open(index_path, 'w') as f:
            f.write("# Claude Todo — Session Index\n\n")
            f.write("| Date | Group | Task | Session | Link |\n")
            f.write("|------|-------|------|---------|------|\n")

    with open(index_path, 'a') as f:
        f.write(f"| {now} | {group_title} | {task_title} | #{session_num} | [[{md_relpath}]] |\n")


def main():
    parser = argparse.ArgumentParser(description='Parse Claude stream-json logs to Obsidian markdown')
    parser.add_argument('--raw-log', required=True, help='Path to raw stream-json log')
    parser.add_argument('--debug-log', default='', help='Path to debug log')
    parser.add_argument('--task-title', required=True)
    parser.add_argument('--group-title', required=True)
    parser.add_argument('--group-date', required=True)
    parser.add_argument('--session-num', required=True, type=int)
    parser.add_argument('--obsidian-dir', required=True)
    args = parser.parse_args()

    # Parse events
    events = parse_stream_json(args.raw_log)
    session_info = extract_session_info(events)
    actions = extract_actions(events)

    print(f"  Parsed {len(events)} events, {len(actions)} actions")

    # Generate markdown
    md_content = generate_markdown(
        args.task_title, args.group_title, args.session_num,
        session_info, actions, args.debug_log
    )

    # Write to Obsidian vault
    safe_group = args.group_title.replace(' ', '-').replace('/', '-')[:40]
    safe_task = args.task_title.replace(' ', '-').replace('/', '-')[:40]
    date_dir = os.path.join(args.obsidian_dir, args.group_date)
    group_dir = os.path.join(date_dir, safe_group)
    os.makedirs(group_dir, exist_ok=True)

    md_filename = f"{args.session_num:03d}-{safe_task}.md"
    md_path = os.path.join(group_dir, md_filename)
    md_relpath = f"{args.group_date}/{safe_group}/{md_filename}"

    with open(md_path, 'w') as f:
        f.write(md_content)

    print(f"  Written to: {md_path}")

    # Update index
    update_index(args.obsidian_dir, args.group_title, args.group_date,
                 args.session_num, args.task_title, md_filename, md_relpath)

    print(f"  Index updated")


if __name__ == '__main__':
    main()
