# Sidecars

Small tools that run next to a Multica install but aren't part of the app:
pollers, bridges and glue for my own setup. Nothing here is built, shipped or
tested by the root `pnpm`/`make` commands, and the app never imports it.

## Conventions

- One directory per sidecar, each with its own `README.md` that covers what it
  does, what data it touches, and how to install and remove it.
- Talk to Multica through the `multica` CLI or the public API, never the
  database. That keeps a sidecar working across upgrades.
- Python sidecars are single-file `uv` scripts (`#!/usr/bin/env -S uv run --script`
  with inline metadata), stdlib-only unless a dependency is really needed. Tests
  sit beside the script and run with `uv run --script test_<name>.py`.
- Keep state and logs outside the repo (`~/.local/state/multica-sidecars/`).
- Don't add network destinations beyond Multica itself and the services the
  sidecar exists to bridge.

## Index

| Sidecar | Purpose |
| --- | --- |
| [github-pr-poller](github-pr-poller/) | Moves Multica issues to Done when their GitHub PRs merge, without a GitHub App or webhooks. |
