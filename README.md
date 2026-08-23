# RunnerBar

A [SwiftBar](https://github.com/swiftbar/SwiftBar) plugin that puts a
self-hosted GitHub Actions runner in the macOS menu bar — and keeps it off
your battery.

Running your own runner is the free-tier escape hatch for private repos, but
the stock installation has two gaps on a laptop: it happily burns battery in
the background, and it's invisible — you can't tell whether it's idle,
mid-job, or how much work is queued. RunnerBar is one shell script that closes
both.

## What it does

- **Power policy** — the runner service is up on AC power and stopped on
  battery. It never kills a job mid-run (that would fail your CI for
  nothing): a running job finishes, then the next refresh stops the service.
- **Menu bar status** — SF Symbol glyphs matching the native menu bar style:
  - 📡 idle, listening for jobs
  - ⚙️ *N*m — job running, with elapsed minutes beside the glyph
  - 🌙 stopped on battery
  - ⏸ paused manually (toggle in the dropdown)
- **The dropdown** — what the runner is working on right now, the queue in
  execution order, and recent runs with their durations. Every line links to
  its run on GitHub.

## Requirements

- macOS with [SwiftBar](https://github.com/swiftbar/SwiftBar)
  (`brew install --cask swiftbar`)
- A self-hosted runner installed the standard way — configured in
  `~/actions-runner` and registered as a launchd service via `./svc.sh install`
- [`gh`](https://cli.github.com), authenticated, for the queue and history
  sections (without it the status and power policy still work)

## Install

```sh
git clone https://github.com/XDGFX/runnerbar.git
ln -s "$PWD/runnerbar/runnerbar.30s.sh" <your SwiftBar plugin folder>/
```

That's it — no configuration. The plugin reads the repository from the
runner's own `.runner` file and finds the launchd service from its plist. If
your runner lives somewhere other than `~/actions-runner`, set `RUNNERBAR_DIR`
in the plugin's environment.

## Notes

- The policy runs on the plugin's 30-second refresh, because launchd has no
  power-source condition. If SwiftBar isn't running, the runner stays in
  whatever state it was last left in.
- One runner per machine is assumed (the first
  `actions.runner.*.plist` found wins).
- GitHub deregisters a runner that stays offline for 14 days; on a
  daily-driver laptop that never comes up.

## Licence

MIT.
