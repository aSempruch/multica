# GitHub PR poller

Moves Multica issues to Done (or another status) when their GitHub pull requests
merge. It replaces the GitHub App's merge-to-done behavior when you can't create
or install the App, or when GitHub can't reach your Multica server.

## How it works

Every run (default: every 5 minutes under launchd):

1. Asks GitHub for PRs merged since the last run, using `gh` and your existing
   login: `gh pr list --state merged --search merged:>=…`.
2. Finds issue IDs the way the App does: any `MUL-123` in the PR title or branch
   name, or in the body right after `Closes`/`Fixes`/`Resolves`.
3. Holds an issue back while another open PR in the same repo still links to it.
4. Otherwise runs `multica issue status MUL-123 done --no-start`. It skips
   issues that are already done, cancelled, at the target status, or not in the
   workspace.

Each PR/issue pair is handled once, so reopening an issue by hand after its PR
merged sticks. Failed or held-back moves are retried on the next run.

**Data flow:** your machine → GitHub (read-only PR listings, as you), and your
machine → your Multica server (through the `multica` CLI). Nothing else.
GitHub never connects to you, and no webhook or tunnel is involved.

## Differences from the GitHub App

- Issues don't get a PR card, CI status or merge state. The poller only changes
  status and posts no comments, because a comment can start the assignee's run.
- Changes land up to one interval late.
- The `pull_request: merged` wakeup condition never fires, since it reads PR
  data only the App provides. Wake on the status instead, i.e. an `issue_field`
  condition with `status = done`. The parent issue still hears about its
  sub-issue closing, the same as with an App merge.
- It works with GitHub Enterprise Server too: set `GH_HOST` (or log `gh` into
  that host), which the App integration doesn't support.

## Requirements

- `uv`, plus `gh` logged into the GitHub that hosts the repos (`gh auth status`).
- The `multica` CLI logged into the server, with the target workspace as its
  default. Pass `--multica-arg=--profile=<name>` or
  `--multica-arg=--workspace-id=<id>` to pick another one.

## Usage

Try it without changing anything first:

```bash
./poll.py --repo acme/app --prefix MUL --dry-run
```

Install it as a launchd job (macOS). The arguments after `install` are passed to
`poll.py`:

```bash
./launchd.sh install --repo acme/app --repo acme/api --prefix MUL
INTERVAL=120 ./launchd.sh install ...   # run every 2 minutes instead of 5
./launchd.sh uninstall
```

The job captures your current `PATH` so launchd can find `gh` and `multica`.
Re-run `install` after moving either one.

| Option | Default | |
| --- | --- | --- |
| `--repo owner/name` | required, repeatable | Repos to watch |
| `--prefix` | required | The workspace's issue prefix |
| `--status` | `done` | Status key to move issues to |
| `--lookback-hours` | `24` | How far back the first run looks |
| `--limit` | `200` | Max merged PRs fetched per repo per run |
| `--state-file` | `~/.local/state/multica-sidecars/github-pr-poller.json` | |

Logs go to `~/Library/Logs/multica-sidecars/github-pr-poller.log`.

## Tests

```bash
uv run --script test_poll.py
```
