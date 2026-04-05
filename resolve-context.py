#!/usr/bin/env python3
"""
Context Resolver for Claude Todo tasks.

Reads a task file, resolves repo references from repo-registry.json,
and outputs an enriched prompt with all necessary context injected.

Usage:
  python3 resolve-context.py task.json           # Print enriched prompts
  python3 resolve-context.py task.json --enrich   # Write enriched version back
"""

import json
import os
import sys
from pathlib import Path

REGISTRY_PATH = os.path.expanduser("~/claude-auto/repo-registry.json")


def load_registry():
    with open(REGISTRY_PATH) as f:
        return json.load(f)["repos"]


def resolve_repo_context(repo_ids, registry):
    """Build a context block from repo IDs."""
    if not repo_ids:
        return ""

    lines = ["# Repository Context (auto-injected by Claude Todo)\n"]

    primary = []
    related = set()

    for rid in repo_ids:
        repo = registry.get(rid)
        if not repo:
            lines.append(f"⚠ Unknown repo: {rid}\n")
            continue

        primary.append(repo)
        # Collect related repos (dependencies + dependents)
        for dep in repo.get("dependsOn", []):
            if dep not in repo_ids:
                related.add(dep)
        for dep in repo.get("dependedBy", []):
            if dep not in repo_ids:
                related.add(dep)

    # Primary repos
    for repo in primary:
        path = repo.get("path", "?")
        lines.append(f"## {repo['name']}")
        lines.append(f"- **Path**: `{path}`")
        lines.append(f"- **Description**: {repo.get('description', '')}")
        lines.append(f"- **Tech**: {', '.join(repo.get('tech', []))}")
        lines.append(f"- **Tier**: {repo.get('tier', 'unknown')}")

        if repo.get("dependsOn"):
            deps = [f"`{d}`" for d in repo["dependsOn"]]
            lines.append(f"- **Depends on**: {', '.join(deps)}")

        if repo.get("dependedBy"):
            deps = [f"`{d}`" for d in repo["dependedBy"]]
            lines.append(f"- **Used by**: {', '.join(deps)}")

        if repo.get("apis"):
            apis = repo["apis"]
            if apis.get("exposes"):
                lines.append(f"- **Exposes**: {', '.join(apis['exposes'])}")
            if apis.get("consumes"):
                lines.append(f"- **Consumes**: {', '.join(apis['consumes'])}")

        if repo.get("notes"):
            lines.append(f"- **⚠ Note**: {repo['notes']}")

        lines.append("")

    # Impact analysis for related repos
    if related:
        lines.append("## Potentially Affected Repos")
        lines.append("Changes to the primary repos above may require updates in:\n")
        for rid in sorted(related):
            repo = registry.get(rid, {})
            path = repo.get("path", "?")
            lines.append(f"- `{rid}` ({repo.get('description', '?')}) at `{path}`")
        lines.append("")

    # Cross-repo communication patterns
    if len(primary) > 1:
        lines.append("## Cross-Repo Communication")
        lines.append("These repos interact. When making changes:\n")
        for repo in primary:
            for dep in repo.get("dependsOn", []):
                if dep in repo_ids:
                    lines.append(f"- `{repo['name']}` consumes `{dep}` — check interface compatibility")
            for dep in repo.get("dependedBy", []):
                if dep in repo_ids:
                    lines.append(f"- `{dep}` depends on `{repo['name']}` — check for breaking changes")
        lines.append("")

    return "\n".join(lines)


def build_working_dirs(repo_ids, registry):
    """Build --add-dir flags for Claude CLI."""
    dirs = []
    for rid in repo_ids:
        repo = registry.get(rid, {})
        path = repo.get("path", "")
        if path:
            dirs.append(os.path.expanduser(path))
    return dirs


def enrich_task(task_data, registry):
    """Enrich a task file with resolved context."""
    repo_ids = task_data.get("repos", [])
    if not repo_ids:
        return task_data

    context = resolve_repo_context(repo_ids, registry)
    working_dirs = build_working_dirs(repo_ids, registry)

    # Store resolved context
    task_data["_resolvedContext"] = context
    task_data["_workingDirs"] = working_dirs

    # Prepend context to each task prompt
    for task in task_data.get("tasks", []):
        if not task.get("prompt", "").startswith("# Repository Context"):
            task["prompt"] = context + "\n---\n\n" + task.get("prompt", "")

    return task_data


def print_summary(task_data, registry):
    """Print a human-readable summary of what the task touches."""
    repo_ids = task_data.get("repos", [])
    goal = task_data.get("goal", "")
    cross_repo = task_data.get("crossRepo", {})

    print(f"Task: {task_data.get('batch', task_data.get('title', '?'))}")
    print(f"Goal: {goal}")
    print(f"Repos: {', '.join(repo_ids)}")

    if cross_repo:
        if cross_repo.get("sharedModels"):
            print(f"Shared models: {', '.join(cross_repo['sharedModels'])}")
        if cross_repo.get("sharedAPIs"):
            print(f"Shared APIs: {', '.join(cross_repo['sharedAPIs'])}")
        if cross_repo.get("migrationRequired"):
            print(f"⚠ Migration required: {cross_repo['migrationRequired']}")

    # Impact analysis
    all_affected = set()
    for rid in repo_ids:
        repo = registry.get(rid, {})
        for dep in repo.get("dependedBy", []):
            if dep not in repo_ids:
                all_affected.add(dep)

    if all_affected:
        print(f"Potentially affected: {', '.join(sorted(all_affected))}")

    print()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: resolve-context.py <task.json> [--enrich|--summary]")
        sys.exit(1)

    task_path = sys.argv[1]
    mode = sys.argv[2] if len(sys.argv) > 2 else "--summary"

    with open(task_path) as f:
        task_data = json.load(f)

    registry = load_registry()

    if mode == "--enrich":
        enriched = enrich_task(task_data, registry)
        with open(task_path, "w") as f:
            json.dump(enriched, f, indent=2)
        print(f"Enriched {task_path}")
    elif mode == "--context":
        repo_ids = task_data.get("repos", [])
        print(resolve_repo_context(repo_ids, registry))
    else:
        print_summary(task_data, registry)
