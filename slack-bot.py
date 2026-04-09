#!/usr/bin/env python3
"""
Slack Bot for Claude Todo — polls for @Claudebot mentions, executes via Claude CLI.
Zero dependencies beyond Python stdlib.
"""

import json
import os
import re
import subprocess
import sys
import time
import urllib.request
import urllib.error
import urllib.parse

# === Configuration ===
HOME = os.path.expanduser("~")
CLAUDE_BIN = os.path.join(HOME, ".local", "bin", "claude")
STATE_FILE = os.path.join(HOME, "claude-auto", ".slack-bot-state.json")
ENV_FILE = os.path.join(HOME, "claude-auto", "slack-bot.env")
LOCK_FILE = os.path.join(HOME, "claude-auto", ".slack-bot.lock")
LOG_DIR = os.path.join(HOME, "claude-auto", "logs")

MODEL = "sonnet"
MAX_BUDGET = 2.0
TIMEOUT = 120  # seconds per Claude execution
MAX_PROCESSED = 500  # cap on processed message IDs to retain

TIMESTAMP = time.strftime("%Y%m%d_%H%M%S")
LOG_FILE = os.path.join(LOG_DIR, f"slack_bot_{TIMESTAMP}.log")


def log(msg):
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


# === Lock ===
def acquire_lock():
    if os.path.exists(LOCK_FILE):
        try:
            pid = int(open(LOCK_FILE).read().strip())
            os.kill(pid, 0)  # check if alive
            return False
        except (ValueError, OSError):
            pass  # stale lock
    with open(LOCK_FILE, "w") as f:
        f.write(str(os.getpid()))
    return True


def release_lock():
    try:
        os.remove(LOCK_FILE)
    except OSError:
        pass


# === Env ===
def load_env():
    env = {}
    if not os.path.exists(ENV_FILE):
        log(f"ERROR: {ENV_FILE} not found")
        sys.exit(1)
    with open(ENV_FILE) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    return env


# === State ===
def load_state():
    if os.path.exists(STATE_FILE):
        with open(STATE_FILE) as f:
            return json.load(f)
    return {"lastProcessedTs": {}, "processedMessages": []}


def save_state(state):
    # Cap processed messages
    state["processedMessages"] = state["processedMessages"][-MAX_PROCESSED:]
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)


# === Slack API ===
def slack_api(method, token, params=None):
    url = f"https://slack.com/api/{method}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json; charset=utf-8",
    }
    data = json.dumps(params or {}).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")

    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = json.loads(resp.read().decode("utf-8"))
            if not body.get("ok"):
                log(f"Slack API {method} error: {body.get('error', 'unknown')}")
            return body
    except urllib.error.HTTPError as e:
        if e.code == 429:
            retry_after = int(e.headers.get("Retry-After", 5))
            log(f"Rate limited, retry after {retry_after}s")
            time.sleep(retry_after)
            return slack_api(method, token, params)
        log(f"Slack API {method} HTTP {e.code}: {e.reason}")
        return {"ok": False, "error": str(e)}
    except Exception as e:
        log(f"Slack API {method} exception: {e}")
        return {"ok": False, "error": str(e)}


def get_bot_user_id(token):
    resp = slack_api("auth.test", token)
    if resp.get("ok"):
        return resp["user_id"]
    log(f"Failed to get bot user ID: {resp.get('error')}")
    sys.exit(1)


def get_bot_channels(token):
    channels = []
    cursor = ""
    while True:
        params = {"types": "public_channel,private_channel", "limit": 200, "exclude_archived": True}
        if cursor:
            params["cursor"] = cursor
        resp = slack_api("conversations.list", token, params)
        if not resp.get("ok"):
            break
        for ch in resp.get("channels", []):
            if ch.get("is_member"):
                channels.append(ch["id"])
        cursor = resp.get("response_metadata", {}).get("next_cursor", "")
        if not cursor:
            break
    return channels


def get_new_messages(token, channel_id, oldest_ts, bot_user_id):
    params = {"channel": channel_id, "oldest": oldest_ts, "limit": 50, "inclusive": False}
    resp = slack_api("conversations.history", token, params)
    if not resp.get("ok"):
        return []

    mention_pattern = f"<@{bot_user_id}>"
    messages = []
    for msg in resp.get("messages", []):
        text = msg.get("text", "")
        # Skip bot's own messages
        if msg.get("bot_id") or msg.get("subtype") == "bot_message":
            continue
        # Check for bot mention
        if mention_pattern not in text:
            continue
        # Extract prompt: strip the mention and leading/trailing whitespace
        prompt = re.sub(r"<@[A-Z0-9]+>", "", text).strip()
        if not prompt:
            continue
        messages.append({
            "channel": channel_id,
            "ts": msg["ts"],
            "user": msg.get("user", "unknown"),
            "prompt": prompt,
        })
    return messages


# === Claude Execution ===
def execute_prompt(prompt, model=MODEL, max_budget=MAX_BUDGET):
    cmd = [
        CLAUDE_BIN, "--print",
        "--dangerously-skip-permissions",
        "--model", model,
        "--max-budget-usd", str(max_budget),
        prompt,
    ]
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=TIMEOUT
        )
        output = result.stdout.strip()
        if not output and result.stderr:
            output = f"Error: {result.stderr.strip()[:500]}"
        return output, result.returncode
    except subprocess.TimeoutExpired:
        return f"Execution timed out after {TIMEOUT}s", 1
    except Exception as e:
        return f"Execution failed: {e}", 1


# === Slack Response ===
def post_reaction(token, channel, ts, emoji):
    slack_api("reactions.add", token, {"channel": channel, "timestamp": ts, "name": emoji})


def remove_reaction(token, channel, ts, emoji):
    slack_api("reactions.remove", token, {"channel": channel, "timestamp": ts, "name": emoji})


def post_reply(token, channel, thread_ts, text):
    MAX_LEN = 3900  # leave margin under Slack's 4000 char limit

    if len(text) <= MAX_LEN:
        slack_api("chat.postMessage", token, {
            "channel": channel,
            "thread_ts": thread_ts,
            "text": text,
        })
        return

    # Split into multiple messages
    chunks = []
    while text:
        if len(text) <= MAX_LEN:
            chunks.append(text)
            break
        # Find a good split point
        split_at = text.rfind("\n", 0, MAX_LEN)
        if split_at < MAX_LEN // 2:
            split_at = MAX_LEN
        chunks.append(text[:split_at])
        text = text[split_at:].lstrip("\n")

    for i, chunk in enumerate(chunks):
        prefix = f"_({i+1}/{len(chunks)})_\n" if len(chunks) > 1 else ""
        slack_api("chat.postMessage", token, {
            "channel": channel,
            "thread_ts": thread_ts,
            "text": prefix + chunk,
        })
        if i < len(chunks) - 1:
            time.sleep(0.5)  # respect rate limits between messages


def parse_flags(prompt):
    """Extract --model and --queue flags from prompt text."""
    model = MODEL
    queue = False

    model_match = re.search(r"--model\s+(sonnet|opus|haiku)", prompt)
    if model_match:
        model = model_match.group(1)
        prompt = prompt[:model_match.start()] + prompt[model_match.end():]

    if "--queue" in prompt:
        queue = True
        prompt = prompt.replace("--queue", "")

    return prompt.strip(), model, queue


def route_to_queue(prompt, user, channel, thread_ts):
    """Route a task to the shared-repo dispatcher pipeline."""
    shared_repo = os.path.join(HOME, "claude-auto", "shared-repo")
    queue_dir = os.path.join(shared_repo, "queue")

    slug = re.sub(r"[^a-z0-9]+", "-", prompt.lower()[:40]).strip("-") or "slack-task"
    batch_file = os.path.join(queue_dir, f"50-slack-{slug}.json")

    batch = {
        "batch": f"slack-{slug}",
        "description": prompt[:200],
        "author": user,
        "priority": 50,
        "model": MODEL,
        "pipeline": "slack-queue",
        "repos": [],
        "slackContext": {
            "channelId": channel,
            "threadTs": thread_ts,
            "user": user,
        },
        "tasks": [{
            "title": f"Process request from {user}",
            "prompt": prompt,
            "verification": "",
            "expectedResult": "",
        }],
    }

    os.makedirs(queue_dir, exist_ok=True)
    with open(batch_file, "w") as f:
        json.dump(batch, f, indent=2)

    # Git commit and push
    try:
        subprocess.run(["git", "-C", shared_repo, "add", "-A"], check=True, capture_output=True)
        subprocess.run(
            ["git", "-C", shared_repo, "commit", "-m",
             f"queue(slack): @Claudebot request [{time.strftime('%H:%M')}]"],
            check=True, capture_output=True
        )
        subprocess.run(["git", "-C", shared_repo, "push", "origin", "main"],
                        capture_output=True, timeout=15)
    except Exception as e:
        log(f"Git push failed: {e}")

    return True


# === Main ===
def main():
    os.makedirs(LOG_DIR, exist_ok=True)

    if not acquire_lock():
        sys.exit(0)  # another instance running

    try:
        env = load_env()
        token = env.get("SLACK_BOT_TOKEN", "")
        if not token or token == "xoxb-YOUR-TOKEN-HERE":
            log("ERROR: Set SLACK_BOT_TOKEN in slack-bot.env")
            return

        state = load_state()
        bot_user_id = get_bot_user_id(token)
        log(f"Bot user ID: {bot_user_id}")

        channels = get_bot_channels(token)
        if not channels:
            log("No channels found — invite @Claudebot to channels first")
            return
        log(f"Monitoring {len(channels)} channel(s)")

        new_messages = []
        for ch in channels:
            oldest = state["lastProcessedTs"].get(ch, str(time.time() - 300))
            msgs = get_new_messages(token, ch, oldest, bot_user_id)
            for msg in msgs:
                if msg["ts"] not in state["processedMessages"]:
                    new_messages.append(msg)

        if not new_messages:
            log("No new mentions")
            return

        log(f"Processing {len(new_messages)} new mention(s)")

        for msg in new_messages:
            ts = msg["ts"]
            channel = msg["channel"]
            user = msg["user"]
            raw_prompt = msg["prompt"]

            log(f"  Message from {user}: {raw_prompt[:80]}...")

            # React with eyes (processing)
            post_reaction(token, channel, ts, "eyes")

            # Parse flags
            prompt, model, queue = parse_flags(raw_prompt)

            if queue:
                # Route to dispatcher pipeline
                route_to_queue(prompt, user, channel, ts)
                post_reply(token, channel, ts,
                           "Queued for batch execution. Results will be posted here when complete.")
                remove_reaction(token, channel, ts, "eyes")
                post_reaction(token, channel, ts, "hourglass_flowing_sand")
            else:
                # Direct execution
                output, exit_code = execute_prompt(prompt, model=model)

                if exit_code == 0 and output:
                    post_reply(token, channel, ts, output)
                    remove_reaction(token, channel, ts, "eyes")
                    post_reaction(token, channel, ts, "white_check_mark")
                else:
                    error_msg = output or "No output from Claude"
                    post_reply(token, channel, ts, f"Failed (exit {exit_code}):\n```\n{error_msg}\n```")
                    remove_reaction(token, channel, ts, "eyes")
                    post_reaction(token, channel, ts, "x")

                log(f"  Exit: {exit_code}, output: {len(output)} chars")

            # Update state
            state["processedMessages"].append(ts)
            state["lastProcessedTs"][channel] = max(
                state["lastProcessedTs"].get(channel, "0"), ts
            )

        save_state(state)
        log("Done")

    finally:
        release_lock()


if __name__ == "__main__":
    main()
