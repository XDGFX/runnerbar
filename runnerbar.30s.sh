#!/bin/bash
# RunnerBar — a SwiftBar plugin for a self-hosted GitHub Actions runner.
#
# Shows the runner in the macOS menu bar and keeps it power-aware: the runner
# is up on AC power and stopped on battery — but never killed mid-job, since a
# killed job fails CI; the active job finishes, then the next refresh stops the
# service. The dropdown shows the run being worked, the queue in execution
# order, and recent runs with durations.
#
# Runs every 30s (the .30s. in the filename). The policy lives here rather
# than in launchd because launchd has no power-source condition. Consequence:
# if SwiftBar isn't running, the runner stays in whatever state it was last in.
#
# Zero config. Everything is read from the runner's own installation:
#   - runner directory: ~/actions-runner (override with RUNNERBAR_DIR)
#   - repository: the gitHubUrl in the runner's .runner file
#   - launchd label: the actions.runner.*.plist in ~/Library/LaunchAgents
# The queue/history sections need `gh` installed and authenticated; without it
# the plugin still runs and simply shows "GitHub unreachable".

# SwiftBar launches plugins with a lean environment; gh and docker usually
# live under Homebrew.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

RUNNER_DIR="${RUNNERBAR_DIR:-$HOME/actions-runner}"
PAUSE_FLAG="$RUNNER_DIR/.runnerbar-paused"

REPO=$(sed -n 's|.*"gitHubUrl": "https://github.com/\([^"]*\)".*|\1|p' "$RUNNER_DIR/.runner" 2>/dev/null)
REPO="${REPO%/}"
SVC_PLIST=$(ls "$HOME/Library/LaunchAgents"/actions.runner.*.plist 2>/dev/null | head -1)
SVC_LABEL=$(basename "$SVC_PLIST" .plist)

if [ -z "$REPO" ] || [ -z "$SVC_LABEL" ]; then
    echo "| sfimage=exclamationmark.triangle"
    echo "---"
    echo "No runner found at $RUNNER_DIR | sfcolor=gray"
    echo "Install one, or set RUNNERBAR_DIR in this plugin's environment | sfcolor=gray"
    exit 0
fi

# --- Manual toggle handlers (invoked from the dropdown, not on refresh) ------
if [ "$1" = "pause" ]; then
    touch "$PAUSE_FLAG"
    cd "$RUNNER_DIR" && ./svc.sh stop >/dev/null 2>&1
    exit 0
fi
if [ "$1" = "resume" ]; then
    rm -f "$PAUSE_FLAG"
    cd "$RUNNER_DIR" && ./svc.sh start >/dev/null 2>&1
    exit 0
fi

# --- Observe ----------------------------------------------------------------
on_ac=false
pmset -g batt | grep -q "AC Power" && on_ac=true

loaded=false
launchctl list "$SVC_LABEL" >/dev/null 2>&1 && loaded=true

job_running=false
worker_mins=""
if pgrep -qx Runner.Worker; then
    job_running=true
    # etime is MM:SS or HH:MM:SS; runs of a day or more would need the DD- form,
    # but job timeouts make that academic.
    worker_mins=$(ps -o etime= -p "$(pgrep -x Runner.Worker | head -1)" |
        awk -F: '{ if (NF == 3) print $1 * 60 + $2; else print $1 + 0 }')
fi

paused=false
[ -f "$PAUSE_FLAG" ] && paused=true

# --- Keep the Mac awake while a job runs ------------------------------------
# CPU load alone does not stop macOS idle-sleep — only a power assertion does,
# and a Mac that dozes mid-job drops off GitHub, which fails the job after ten
# minutes of silence. Pin an assertion to the worker process: `caffeinate -i`
# holds it exactly until that pid exits, so an idle runner still lets the
# machine sleep normally (queued jobs wait and start on wake). A closed lid
# still sleeps regardless — clamshell mode outranks assertions.
if $job_running; then
    worker_pid=$(pgrep -x Runner.Worker | head -1)
    if ! pgrep -f "caffeinate -i -w $worker_pid" >/dev/null; then
        nohup caffeinate -i -w "$worker_pid" >/dev/null 2>&1 &
    fi
fi

# --- Enforce ----------------------------------------------------------------
if ! $paused; then
    if $on_ac && ! $loaded; then
        cd "$RUNNER_DIR" && ./svc.sh start >/dev/null 2>&1
        loaded=true
    elif ! $on_ac && $loaded && ! $job_running; then
        cd "$RUNNER_DIR" && ./svc.sh stop >/dev/null 2>&1
        loaded=false
    fi
fi

# --- Draw -------------------------------------------------------------------
# SF Symbols as template images, to sit flush with the other menu bar apps.
# While a job runs, the elapsed minutes ride next to the glyph.
if $paused; then
    header="| sfimage=pause.circle"
    state="Paused manually"
elif $job_running; then
    # A plain leading space gets trimmed from the title; a non-breaking space
    # (UTF-8 C2 A0) survives, and puts air between the glyph and the number.
    # sfsize pins the glyph to standard menu-bar symbol size — unpinned it
    # renders oversized and visually swallows the gap before the number.
    header="$(printf '\xc2\xa0')${worker_mins}m | sfimage=gearshape.arrow.triangle.2.circlepath sfsize=13"
    state="Job running (${worker_mins}m elapsed)"
elif $loaded; then
    header="| sfimage=antenna.radiowaves.left.and.right"
    state="Idle, listening for jobs"
else
    header="| sfimage=moon.zzz"
    state="Stopped (on battery)"
fi

echo "$header"
echo "---"
echo "CI runner: $state | sfcolor=gray"
echo "---"

# --- Run queue and history ---------------------------------------------------
# One API call covers all three sections. Skipped when asleep on battery —
# no point spending radio time on a runner that isn't going to pick jobs up.
runs_json=""
if $loaded || $job_running || $on_ac; then
    runs_json=$(gh run list -R "$REPO" --limit 20 \
        --json displayTitle,status,conclusion,createdAt,startedAt,updatedAt,headBranch,url 2>/dev/null)
fi

if [ -n "$runs_json" ]; then
    python3 - "$runs_json" "$worker_mins" <<'EOF'
import datetime
import json
import sys

runs = json.loads(sys.argv[1])
now = datetime.datetime.now(datetime.timezone.utc)


def when(stamp):
    return datetime.datetime.fromisoformat(stamp.replace('Z', '+00:00'))


def mins(start, end):
    return f"{max(0, round((end - start).total_seconds() / 60))}m"


def line(run, suffix, icon):
    # A literal | would read as a SwiftBar parameter separator.
    title = run['displayTitle'].replace('|', '¦')
    title = title if len(title) <= 55 else title[:54] + '…'
    print(f"{title}{suffix} | href={run['url']} sfimage={icon} sfsize=12")


active = [r for r in runs if r['status'] == 'in_progress']
queued = [r for r in runs if r['status'] in ('queued', 'waiting', 'requested', 'pending')]
done = [r for r in runs if r['status'] == 'completed'][:4]

# A single runner drains the queue oldest-first, so show it in that order —
# and GitHub reports a run as merely "queued" between its serial jobs, so when
# the worker process is alive but no run says in_progress, the oldest queued
# run is the one actually being worked. Its elapsed time comes from the worker
# process age (argv[2]), which the API cannot see.
queued.sort(key=lambda r: r['createdAt'])
worker_mins = sys.argv[2]
if not active and queued and worker_mins:
    run = queued.pop(0)
    print("WORKING ON | size=11 sfcolor=gray")
    line(run, f" ({run['headBranch']}) — {worker_mins}m", 'gearshape')
elif active:
    print("WORKING ON | size=11 sfcolor=gray")
    for run in active:
        line(run, f" ({run['headBranch']}) — {mins(when(run['startedAt']), now)}", 'gearshape')
if queued:
    print(f"QUEUED — {len(queued)} WAITING | size=11 sfcolor=gray")
    for run in queued:
        line(run, f" ({run['headBranch']})", 'hourglass')
if done:
    print("RECENTLY COMPLETED | size=11 sfcolor=gray")
    for run in done:
        icon = {'success': 'checkmark.circle', 'failure': 'xmark.circle'}.get(
            run['conclusion'], 'slash.circle')
        line(run, f" — {mins(when(run['startedAt']), when(run['updatedAt']))}", icon)
EOF
elif $loaded || $job_running || $on_ac; then
    echo "GitHub unreachable | sfcolor=gray"
fi

echo "---"
if $paused; then
    echo "Resume runner | bash='$0' param1=resume terminal=false refresh=true"
else
    echo "Pause runner | bash='$0' param1=pause terminal=false refresh=true"
fi
echo "Open Actions on GitHub | href=https://github.com/$REPO/actions"
