#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
import json
import subprocess
import unittest
from datetime import datetime, timezone

from poll import Poller, identifiers, parse_args

NOW = datetime(2026, 10, 6, 12, 0, tzinfo=timezone.utc)


def pr(number, title="", branch="", body="", merged_at="2026-10-06T11:00:00Z"):
    return {"number": number, "url": f"https://github.com/acme/app/pull/{number}", "title": title,
            "headRefName": branch, "body": body, "mergedAt": merged_at}


class FakeTools:
    def __init__(self, merged=(), open_prs=(), statuses=None, fail_status=False):
        self.merged, self.open_prs = list(merged), list(open_prs)
        self.statuses = dict(statuses or {})
        self.fail_status = fail_status
        self.calls = []

    def __call__(self, args):
        self.calls.append(args)
        if args[0] == "gh":
            state = args[args.index("--state") + 1]
            return json.dumps(self.merged if state == "merged" else self.open_prs)
        sub = args[args.index("issue") + 1]
        ident = args[args.index("issue") + 2]
        if sub == "get":
            if ident not in self.statuses:
                raise subprocess.CalledProcessError(4, args, stderr="not found")
            return json.dumps({"identifier": ident, "status": self.statuses[ident]})
        if sub == "status":
            if self.fail_status:
                raise subprocess.CalledProcessError(2, args, stderr="network")
            self.statuses[ident] = args[args.index("issue") + 3]
            return ""
        raise AssertionError(args)

    def moves(self):
        return [a for a in self.calls if a[0] == "multica" and "status" in a]


def run(tools, state=None, *extra):
    opts = parse_args(["--repo", "acme/app", "--prefix", "MUL", *extra])
    logs = []
    new_state = Poller(opts, run=tools, log=logs.append).tick(state or {}, NOW)
    return new_state, logs


class IdentifiersTest(unittest.TestCase):
    def test_title_and_branch_link_on_any_mention(self):
        self.assertEqual(identifiers(pr(1, title="mul-12 Fix login", branch="mul-34-x"), "MUL"), {"MUL-12", "MUL-34"})

    def test_body_links_only_after_closing_keyword(self):
        body = "Related to MUL-1\nCloses MUL-2, fixes: MUL-3\nResolved MUL-4"
        self.assertEqual(identifiers(pr(1, body=body), "MUL"), {"MUL-2", "MUL-3", "MUL-4"})

    def test_ignores_other_prefixes_and_embedded_matches(self):
        self.assertEqual(identifiers(pr(1, title="ENG-1 XMUL-2 MUL-3a MUL-0042"), "MUL"), {"MUL-42"})


class TickTest(unittest.TestCase):
    def test_moves_linked_issue_without_starting_a_run(self):
        tools = FakeTools(merged=[pr(7, title="MUL-5 thing")], statuses={"MUL-5": "in_review"})
        state, _ = run(tools)
        self.assertEqual(tools.moves(), [["multica", "issue", "status", "MUL-5", "done", "--no-start"]])
        self.assertIn("https://github.com/acme/app/pull/7#MUL-5", state["handled"])
        self.assertEqual(state["since"], "2026-10-06T12:00:00Z")

    def test_handled_prs_are_not_reprocessed(self):
        tools = FakeTools(merged=[pr(7, title="MUL-5")], statuses={"MUL-5": "in_review"})
        state, _ = run(tools)
        tools.statuses["MUL-5"] = "in_progress"  # reopened by hand after the merge
        run(tools, state)
        self.assertEqual(len(tools.moves()), 1)

    def test_skips_closed_missing_and_already_target(self):
        tools = FakeTools(merged=[pr(1, title="MUL-1 MUL-2 MUL-3")], statuses={"MUL-1": "done", "MUL-2": "cancelled"})
        state, _ = run(tools)
        self.assertEqual(tools.moves(), [])
        self.assertEqual(len(state["handled"]), 3)

    def test_waits_while_an_open_pr_still_links_the_issue(self):
        tools = FakeTools(merged=[pr(1, title="MUL-9", merged_at="2026-10-06T10:00:00Z")],
                          open_prs=[pr(2, branch="mul-9-part-two")], statuses={"MUL-9": "in_review"})
        state, _ = run(tools)
        self.assertEqual(tools.moves(), [])
        self.assertEqual(state["handled"], {})
        self.assertEqual(state["since"], "2026-10-06T10:00:00Z")  # keeps the merge in the next window

        tools.open_prs = []
        run(tools, state)
        self.assertEqual(len(tools.moves()), 1)

    def test_failed_move_is_retried(self):
        tools = FakeTools(merged=[pr(1, title="MUL-4")], statuses={"MUL-4": "todo"}, fail_status=True)
        state, _ = run(tools)
        self.assertEqual(state["handled"], {})
        tools.fail_status = False
        run(tools, state)
        self.assertEqual(tools.statuses["MUL-4"], "done")

    def test_dry_run_changes_nothing(self):
        tools = FakeTools(merged=[pr(1, title="MUL-4")], statuses={"MUL-4": "todo"})
        state, logs = run(tools, None, "--dry-run")
        self.assertEqual(tools.moves(), [])
        self.assertEqual(state["handled"], {})
        self.assertTrue(any(l.startswith("dry-run: would move MUL-4") for l in logs))

    def test_custom_status_and_multica_args(self):
        tools = FakeTools(merged=[pr(1, title="MUL-4")], statuses={"MUL-4": "todo"})
        run(tools, None, "--status", "awaiting_qa", "--multica-arg=--profile=work")
        self.assertEqual(tools.moves(), [["multica", "--profile=work", "issue", "status", "MUL-4", "awaiting_qa", "--no-start"]])

    def test_first_run_uses_lookback_window(self):
        tools = FakeTools()
        run(tools, None, "--lookback-hours", "2")
        search = tools.calls[0][tools.calls[0].index("--search") + 1]
        self.assertEqual(search, "merged:>=2026-10-06T09:45:00Z")  # 2h lookback minus 15m overlap


if __name__ == "__main__":
    unittest.main()
