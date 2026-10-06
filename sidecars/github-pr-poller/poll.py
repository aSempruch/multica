#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Mirror merged GitHub pull requests onto Multica issue statuses.

A stand-in for the GitHub App's "move the issue when its PRs merge" behavior,
for when the App can't be installed or GitHub can't reach the server. Each run
asks GitHub (via `gh`, with the caller's own login) for recently merged PRs,
finds issue identifiers the same way the App does, and moves those issues with
`multica issue status <id> <status> --no-start`. Run it on a timer.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections.abc import Callable
from datetime import datetime, timedelta, timezone
from pathlib import Path

Runner = Callable[[list[str]], str]

DEFAULT_STATE = Path.home() / ".local/state/multica-sidecars/github-pr-poller.json"
# Re-query a little before the last watermark so PRs indexed late by GitHub
# search are not missed; handled PRs are deduplicated through the state file.
OVERLAP = timedelta(minutes=15)
MAX_WINDOW = timedelta(days=14)
FORGET_AFTER = timedelta(days=30)
CLOSED_STATUSES = {"done", "cancelled"}
MULTICA_EXIT_NOT_FOUND = 4  # server/internal/cli/errors.go
PR_FIELDS = "number,url,title,headRefName,body,mergedAt"


def identifiers(pr: dict, prefix: str) -> set[str]:
    """Issue identifiers a PR links to, using the GitHub App's rules.

    The title and branch name link on any mention; the body links only right
    after a closing keyword (Closes/Fixes/Resolves). The patterns mirror
    identifierRe and closingIdentifierRe in server/internal/handler/github.go.
    """
    flags = re.IGNORECASE | re.ASCII
    ident = rf"\b{re.escape(prefix)}-(\d+)\b"
    found = set()
    for text in (pr.get("title") or "", pr.get("headRefName") or ""):
        found.update(re.findall(ident, text, flags))
    closing = rf"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)[:\s]+{ident}"
    found.update(re.findall(closing, pr.get("body") or "", flags))
    return {f"{prefix.upper()}-{int(n)}" for n in found}


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def subprocess_runner(args: list[str]) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


class Poller:
    def __init__(self, opts: argparse.Namespace, run: Runner = subprocess_runner, log=print):
        self.opts = opts
        self.run = run
        self.log = log

    def gh_prs(self, repo: str, *extra: str) -> list[dict]:
        out = self.run([self.opts.gh, "pr", "list", "--repo", repo, "--json", PR_FIELDS, *extra])
        return json.loads(out or "[]")

    def multica(self, *args: str) -> str:
        return self.run([self.opts.multica, *self.opts.multica_arg, *args])

    def tick(self, state: dict, now: datetime) -> dict:
        prefix = self.opts.prefix
        target = self.opts.status
        since = parse_time(state["since"]) if state.get("since") else now - timedelta(hours=self.opts.lookback_hours)
        since = max(since, now - MAX_WINDOW)
        handled: dict[str, str] = dict(state.get("handled", {}))
        oldest_deferred: datetime | None = None
        statuses: dict[str, str | None] = {}

        for repo in self.opts.repo:
            limit = str(self.opts.limit)
            merged = self.gh_prs(repo, "--state", "merged", "--limit", limit, "--search", f"merged:>={iso(since - OVERLAP)}")
            if len(merged) >= self.opts.limit:
                self.log(f"warn: {repo}: hit --limit {limit}; older merges in this window may be skipped")
            if not merged:
                continue
            # An issue waits while any open PR still links to it, like the App.
            waiting = set()
            for pr in self.gh_prs(repo, "--state", "open", "--limit", "500"):
                waiting |= identifiers(pr, prefix)

            for pr in sorted(merged, key=lambda p: p.get("mergedAt") or ""):
                for ident in sorted(identifiers(pr, prefix)):
                    key = f"{pr['url']}#{ident}"
                    if key in handled:
                        continue
                    outcome = self.apply(ident, pr, waiting, statuses)
                    if outcome == "deferred":
                        merged_at = parse_time(pr["mergedAt"])
                        oldest_deferred = min(filter(None, [oldest_deferred, merged_at]))
                    elif not self.opts.dry_run:
                        handled[key] = iso(now)

        next_since = now if oldest_deferred is None else min(now, oldest_deferred)
        cutoff = now - FORGET_AFTER
        handled = {k: v for k, v in handled.items() if parse_time(v) >= cutoff}
        return {"since": iso(next_since), "handled": handled}

    def apply(self, ident: str, pr: dict, waiting: set[str], statuses: dict[str, str | None]) -> str:
        """Move one issue for one merged PR. Returns moved, skipped or deferred."""
        where = f"{ident} ({pr['url']})"
        if ident in waiting:
            self.log(f"wait: {where}: another open PR still links to it")
            return "deferred"
        if ident not in statuses:
            try:
                issue = json.loads(self.multica("issue", "get", ident, "--output", "json"))
                statuses[ident] = issue.get("status")
            except subprocess.CalledProcessError as err:
                if err.returncode == MULTICA_EXIT_NOT_FOUND:
                    self.log(f"skip: {where}: no such issue in this workspace")
                    statuses[ident] = None
                    return "skipped"
                self.log(f"error: {where}: multica issue get failed: {(err.stderr or '').strip()}")
                return "deferred"
        status = statuses[ident]
        if status is None:
            return "skipped"
        if status == self.opts.status or status in CLOSED_STATUSES:
            self.log(f"skip: {where}: already {status}")
            return "skipped"
        if self.opts.dry_run:
            self.log(f"dry-run: would move {where} from {status} to {self.opts.status}")
            return "moved"
        try:
            self.multica("issue", "status", ident, self.opts.status, "--no-start")
        except subprocess.CalledProcessError as err:
            self.log(f"error: {where}: multica issue status failed: {(err.stderr or '').strip()}")
            return "deferred"
        statuses[ident] = self.opts.status
        self.log(f"moved: {where} from {status} to {self.opts.status}")
        return "moved"


def load_state(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return {}


def save_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--repo", action="append", required=True, help="owner/name to watch (repeatable)")
    p.add_argument("--prefix", required=True, help="Multica workspace issue prefix, e.g. MUL")
    p.add_argument("--status", default="done", help="status key to move issues to (default: done)")
    p.add_argument("--lookback-hours", type=float, default=24, help="first-run window (default: 24)")
    p.add_argument("--limit", type=int, default=200, help="max merged PRs fetched per repo per run")
    p.add_argument("--state-file", type=Path, default=DEFAULT_STATE)
    p.add_argument("--gh", default="gh", help="gh executable")
    p.add_argument("--multica", default="multica", help="multica executable")
    p.add_argument("--multica-arg", action="append", default=[], help="extra arg passed before every multica subcommand, e.g. --multica-arg=--profile=work")
    p.add_argument("--dry-run", action="store_true", help="log what would change; touch nothing, save no state")
    return p.parse_args(argv)


def main(argv: list[str]) -> int:
    opts = parse_args(argv)
    now = datetime.now(timezone.utc)
    stamp = lambda msg: print(f"{iso(datetime.now(timezone.utc))} {msg}", flush=True)
    state = load_state(opts.state_file)
    try:
        new_state = Poller(opts, log=stamp).tick(state, now)
    except subprocess.CalledProcessError as err:
        stamp(f"error: {' '.join(err.cmd)} failed: {(err.stderr or '').strip()}")
        return 1
    if not opts.dry_run:
        save_state(opts.state_file, new_state)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
