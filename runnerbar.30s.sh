#!/bin/bash
# RunnerBar — a SwiftBar plugin for self-hosted GitHub Actions runners.
#
# Shows every runner installed on this Mac in the menu bar and keeps them
# power-aware: runners up on AC power, stopped on battery — but never killed
# mid-job, since a killed job fails CI; the active job finishes, then the next
# refresh stops the service. The dropdown shows each runner's identity, the
# run being worked, the queue in execution order, and runs completed in the
# last three days with durations. Runners idle for three days sink to the
# bottom.
#
# Runs every 30s (the .30s. in the filename). The policy lives here rather
# than in launchd because launchd has no power-source condition. Consequence:
# if SwiftBar isn't running, runners stay in whatever state they were last in.
#
# Zero config. Runners are discovered from their launchd plists in
# ~/Library/LaunchAgents (one per runner, created by `./svc.sh install`), and
# each runner's repository and name are read from the `.runner` file in its
# install directory. The queue/history sections need `gh` installed and
# authenticated; without it the plugin still runs and shows "GitHub
# unreachable".
#
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>

# SwiftBar launches plugins with a lean environment; gh and docker usually
# live under Homebrew.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Global settings are flag files here: present = the non-default choice.
# Per-runner pause flags live in each runner's own directory instead, so they
# follow the runner they belong to. All toggled from the dropdown; all survive
# reboots and SwiftBar restarts.
SETTINGS_DIR="$HOME/.config/runnerbar"
NO_CAFFEINATE_FLAG="$SETTINGS_DIR/no-caffeinate"
ALWAYS_RUN_FLAG="$SETTINGS_DIR/always-run"
LOW_POWER_FLAG="$SETTINGS_DIR/low-power"

# Low-power mode confines runner work to the efficiency cores, which is only a
# thing on Apple silicon; elsewhere the toggle is hidden and the flag inert.
e_cores=false
[ "$(uname -m)" = "arm64" ] && e_cores=true

# --- Discover runners --------------------------------------------------------
# One launchd plist per installed runner; its ProgramArguments points at the
# runner directory's runsvc.sh, which is how the directory is recovered. Kept
# as parallel indexed arrays because macOS ships bash 3.2 (no associative
# arrays).
runner_dirs=()
runner_labels=()
runner_names=()
runner_repos=()

for plist in "$HOME/Library/LaunchAgents"/actions.runner.*.plist; do
    [ -f "$plist" ] || continue
    dir=$(sed -n 's|.*<string>\(.*\)/runsvc.sh</string>.*|\1|p' "$plist" | head -1)
    [ -d "$dir" ] || continue
    repo=$(sed -n 's|.*"gitHubUrl": "https://github.com/\([^"]*\)".*|\1|p' "$dir/.runner" 2>/dev/null)
    name=$(sed -n 's|.*"agentName": "\([^"]*\)".*|\1|p' "$dir/.runner" 2>/dev/null)
    [ -n "$repo" ] || continue
    runner_dirs+=("$dir")
    runner_labels+=("$(basename "$plist" .plist)")
    runner_names+=("${name:-$(basename "$dir")}")
    runner_repos+=("${repo%/}")
done

if [ ${#runner_dirs[@]} -eq 0 ]; then
    echo "| sfimage=exclamationmark.triangle"
    echo "---"
    echo "No self-hosted runner found | sfcolor=gray"
    echo "Install one with ./config.sh then ./svc.sh install — see the runner's docs | sfcolor=gray"
    exit 0
fi

# --- Toggle handlers (invoked from the dropdown, not on refresh) -------------
# pause/resume act on one runner: its directory arrives as $2.
case "$1" in
    pause)
        touch "$2/.runnerbar-paused"
        cd "$2" && ./svc.sh stop >/dev/null 2>&1
        exit 0
        ;;
    resume)
        rm -f "$2/.runnerbar-paused"
        cd "$2" && ./svc.sh start >/dev/null 2>&1
        exit 0
        ;;
    toggle-caffeinate)
        mkdir -p "$SETTINGS_DIR"
        if [ -f "$NO_CAFFEINATE_FLAG" ]; then
            rm -f "$NO_CAFFEINATE_FLAG"
        else
            touch "$NO_CAFFEINATE_FLAG"
            # Release any assertion already pinned to a running job.
            pkill -f 'caffeinate -i -w' 2>/dev/null
        fi
        exit 0
        ;;
    toggle-always-run)
        mkdir -p "$SETTINGS_DIR"
        if [ -f "$ALWAYS_RUN_FLAG" ]; then
            rm -f "$ALWAYS_RUN_FLAG"
        else
            touch "$ALWAYS_RUN_FLAG"
        fi
        exit 0
        ;;
    toggle-low-power)
        mkdir -p "$SETTINGS_DIR"
        if [ -f "$LOW_POWER_FLAG" ]; then
            rm -f "$LOW_POWER_FLAG"
            # Lift the background policy from live runner processes now
            # rather than at their next restart.
            for pid in $(pgrep -x Runner.Listener) $(pgrep -x Runner.Worker); do
                taskpolicy -B -p "$pid" 2>/dev/null
            done
        else
            touch "$LOW_POWER_FLAG"
        fi
        exit 0
        ;;
esac

# --- Observe (machine-wide) --------------------------------------------------
on_ac=false
pmset -g batt | grep -q "AC Power" && on_ac=true

caffeinate_on=true
[ -f "$NO_CAFFEINATE_FLAG" ] && caffeinate_on=false

always_run=false
[ -f "$ALWAYS_RUN_FLAG" ] && always_run=true

low_power=false
$e_cores && [ -f "$LOW_POWER_FLAG" ] && low_power=true

# Every live worker process, machine-wide; attributed to runners below by the
# runner directory in its command path.
worker_pids=$(pgrep -x Runner.Worker)

# --- Low-power mode (Apple silicon only, toggleable) -------------------------
# `taskpolicy -b` confines a process and everything it subsequently spawns to
# the efficiency cores, which use less energy per unit of work — not merely
# less power — at the cost of slower jobs. Tagging the listener covers every
# job it starts from then on; tagging live workers catches the job already
# running. Re-applying to an already-tagged pid is a no-op, so this is safe to
# repeat every refresh.
if $low_power; then
    for pid in $(pgrep -x Runner.Listener) $worker_pids; do
        taskpolicy -b -p "$pid" 2>/dev/null
    done
fi

# --- Observe and enforce, per runner -----------------------------------------
runner_loaded=()
runner_paused=()
runner_mins=()

i=0
while [ $i -lt ${#runner_dirs[@]} ]; do
    dir="${runner_dirs[$i]}"

    loaded=false
    launchctl list "${runner_labels[$i]}" >/dev/null 2>&1 && loaded=true

    paused=false
    [ -f "$dir/.runnerbar-paused" ] && paused=true

    # This runner's active job, if any: the worker whose binary lives under
    # this runner's directory. Elapsed minutes from the process age — etime is
    # MM:SS or HH:MM:SS; job timeouts make the day form academic.
    mins=""
    for pid in $worker_pids; do
        if ps -o command= -p "$pid" | grep -q "^$dir/"; then
            mins=$(ps -o etime= -p "$pid" |
                awk -F: '{ if (NF == 3) print $1 * 60 + $2; else print $1 + 0 }')
            # Keep the Mac awake while this job runs (toggleable). CPU load
            # alone does not stop macOS idle-sleep — only a power assertion
            # does, and a Mac that dozes mid-job drops off GitHub, which fails
            # the job after ten minutes of silence. Pinned to the worker pid:
            # held exactly until the job ends, so an idle machine sleeps
            # normally and queued jobs wait for the next wake. A closed lid
            # still sleeps regardless — clamshell mode outranks assertions.
            if $caffeinate_on && ! pgrep -f "caffeinate -i -w $pid" >/dev/null; then
                nohup caffeinate -i -w "$pid" >/dev/null 2>&1 &
            fi
            break
        fi
    done

    # Default: runner up on AC, stopped on battery once the current job
    # finishes. "Run on battery" keeps every runner up whatever the power
    # source; a runner's own pause outranks everything.
    if ! $paused; then
        if { $always_run || $on_ac; } && ! $loaded; then
            cd "$dir" && ./svc.sh start >/dev/null 2>&1
            loaded=true
        elif ! $always_run && ! $on_ac && $loaded && [ -z "$mins" ]; then
            cd "$dir" && ./svc.sh stop >/dev/null 2>&1
            loaded=false
        fi
    fi

    runner_loaded+=("$loaded")
    runner_paused+=("$paused")
    runner_mins+=("$mins")
    i=$((i + 1))
done

# --- Draw the menu bar item --------------------------------------------------
# SF Symbols as template images, to sit flush with the other menu bar apps.
# The aggregate wins: any job running shows the gear (with elapsed minutes, or
# a job count when several run at once); else any listening runner shows the
# antenna; else pause or moon.
jobs_running=0
longest=0
any_loaded=false
all_paused=true
for i in "${!runner_dirs[@]}"; do
    if [ -n "${runner_mins[$i]}" ]; then
        jobs_running=$((jobs_running + 1))
        [ "${runner_mins[$i]}" -gt "$longest" ] && longest="${runner_mins[$i]}"
    fi
    [ "${runner_loaded[$i]}" = "true" ] && any_loaded=true
    [ "${runner_paused[$i]}" = "true" ] || all_paused=false
done

# A plain leading space gets trimmed from the title; a non-breaking space
# (UTF-8 C2 A0) survives, and puts air between the glyph and the number.
# sfsize pins the glyph to standard menu-bar symbol size — unpinned it renders
# oversized and visually swallows the gap before the number.
nbsp=$(printf '\xc2\xa0')
if [ "$jobs_running" -gt 1 ]; then
    echo "${nbsp}${jobs_running} jobs | sfimage=gearshape.arrow.triangle.2.circlepath sfsize=13"
elif [ "$jobs_running" -eq 1 ]; then
    echo "${nbsp}${longest}m | sfimage=gearshape.arrow.triangle.2.circlepath sfsize=13"
elif $all_paused; then
    echo "| sfimage=pause.circle"
elif $any_loaded; then
    echo "| sfimage=antenna.radiowaves.left.and.right"
else
    echo "| sfimage=moon.zzz"
fi
echo "---"

# --- Dropdown: one block per runner ------------------------------------------
# Prints runner $1's block. Returns 3 when the runner has sat idle for three
# days — nothing running, nothing queued, nothing finished — so the caller can
# sink it below the busy ones.
draw_runner() {
    local i=$1 idle=false
    dir="${runner_dirs[$i]}"
    repo="${runner_repos[$i]}"
    mins="${runner_mins[$i]}"

    if [ "${runner_paused[$i]}" = "true" ]; then
        state="Paused manually"
    elif [ -n "$mins" ]; then
        state="Job running (${mins}m elapsed)"
        $on_ac || $always_run || state="Job running — on battery, stops when it finishes"
    elif [ "${runner_loaded[$i]}" = "true" ]; then
        state="Idle, listening for jobs"
    else
        state="Stopped (on battery)"
    fi

    echo "${runner_names[$i]} — $repo: $state | sfcolor=gray"

    # One API call per runner covers all three sections. Skipped when asleep
    # on battery — no point spending radio time on a runner that isn't going
    # to pick jobs up.
    runs_json=""
    if [ "${runner_loaded[$i]}" = "true" ] || [ -n "$mins" ] || $on_ac; then
        runs_json=$(gh run list -R "$repo" --limit 20 \
            --json displayTitle,status,conclusion,createdAt,startedAt,updatedAt,headBranch,url 2>/dev/null)
        if [ -n "$runs_json" ]; then
            python3 - "$runs_json" "$mins" <<'EOF'
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
# Only what finished in the last three days: older runs are history, not news.
cutoff = now - datetime.timedelta(days=3)
done = [r for r in runs
        if r['status'] == 'completed' and when(r['updatedAt']) >= cutoff][:4]

# A runner drains its queue oldest-first, so show it in that order — and
# GitHub reports a run as merely "queued" between its serial jobs, so when the
# worker process is alive but no run says in_progress, the oldest queued run
# is the one actually being worked. Its elapsed time comes from the worker
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
        # Prefer the worker's real age: the API's startedAt includes queue
        # gaps and any time the machine spent asleep mid-run.
        shown = f"{worker_mins}m" if worker_mins and len(active) == 1 else mins(when(run['startedAt']), now)
        line(run, f" ({run['headBranch']}) — {shown}", 'gearshape')
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
if not (active or queued or done or worker_mins):
    print("No runs in the last 3 days | sfcolor=gray")
    sys.exit(3)
EOF
            [ $? -eq 3 ] && idle=true
        else
            echo "GitHub unreachable | sfcolor=gray"
        fi
    fi

    # Per-runner controls; the runner directory rides along as param2.
    if [ "${runner_paused[$i]}" = "true" ]; then
        echo "Resume runner | bash='$0' param1=resume param2='$dir' terminal=false refresh=true"
    else
        echo "Pause runner | bash='$0' param1=pause param2='$dir' terminal=false refresh=true"
    fi
    echo "Open Actions on GitHub | href=https://github.com/$repo/actions"
    echo "---"
    $idle && return 3
    return 0
}

# Busy runners first, idle ones after, each group in discovery order. A runner
# whose runs couldn't be fetched stays with the busy ones — idleness unknown.
idle_blocks=""
for i in "${!runner_dirs[@]}"; do
    block=$(draw_runner "$i")
    if [ $? -eq 3 ]; then
        idle_blocks+="$block"$'\n'
    else
        printf '%s\n' "$block"
    fi
done
printf '%s' "$idle_blocks"

# --- Global settings ----------------------------------------------------------
# Ticked when active. Both act from the next refresh; switching keep-awake off
# also releases the assertion held for a job already running.
caffeinate_checked=false
$caffeinate_on && caffeinate_checked=true
battery_checked=false
$always_run && battery_checked=true
echo "Keep Mac awake during jobs | bash='$0' param1=toggle-caffeinate terminal=false refresh=true checked=$caffeinate_checked"
echo "Run on battery | bash='$0' param1=toggle-always-run terminal=false refresh=true checked=$battery_checked"
if $e_cores; then
    low_power_checked=false
    $low_power && low_power_checked=true
    echo "Low-power mode (efficiency cores) | bash='$0' param1=toggle-low-power terminal=false refresh=true checked=$low_power_checked"
fi
