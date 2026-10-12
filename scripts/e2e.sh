#!/usr/bin/env bash
# End-to-end test with real signals, tmux and hooks, without a real memory crisis.
#
# A fake agent (a shell whose argv[0] is "claude") runs in a tmux pane and starts a
# 3-process, 3GB test job in its own process group. oomguard then runs against simulated
# readings, with a `never` rule that protects every job except the test job.
#
#   1. occupancy 65%  -> warn hook, message typed into the agent's pane, no kill
#   2. occupancy 86%  -> the test job is killed, pre/post hooks run, the agent survives
#   3. `oomguard exec --max-gb` -> the kernel kills a process that passes its cap
#
# Needs tmux and clang. State goes to a temp dir, not ~/.local/state.
set -euo pipefail

OOMGUARD=${OOMGUARD:-$(cd "$(dirname "$0")/.." && pwd)/.build/debug/oomguard}
WORK=$(mktemp -d)
SESSION=oomguard-e2e-$$
export XDG_STATE_HOME=$WORK/state
trap 'tmux kill-session -t "$SESSION" 2>/dev/null || true; pkill -f "oomguard-e2e-pool" 2>/dev/null || true; rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; cat "$WORK"/*.log 2>/dev/null || true; exit 1; }

cat > "$WORK/pool.c" <<'EOF'
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    int processes = argc > 1 ? atoi(argv[1]) : 3;
    size_t mb = argc > 2 ? atoi(argv[2]) : 1024;
    for (int i = 1; i < processes; i++) if (fork() == 0) break;
    char *p = malloc(mb << 20); memset(p, 1, mb << 20);   /* touch it so it counts */
    sleep(120);
    return 0;
}
EOF
clang -O0 -o "$WORK/oomguard-e2e-pool" "$WORK/pool.c"

cat > "$WORK/config.toml" <<EOF
[victim]
min_size_gb = 1
never = ["^(?!.*oomguard-e2e-pool)"]
[notify]
enabled = false
[hooks]
on_warn = "echo warn >> $WORK/hooks.log"
on_agent_job = "echo agent \$OOMGUARD_AGENT_NAME >> $WORK/hooks.log"
pre_kill = "echo pre_kill >> $WORK/hooks.log"
post_kill = "echo post_kill >> $WORK/hooks.log"
EOF

tmux new-session -d -s "$SESSION" -c "$WORK" "bash -c 'exec -a claude bash -c \"set -m; $WORK/oomguard-e2e-pool & cat\"'"
for _ in $(seq 30); do
    "$OOMGUARD" status -c "$WORK/config.toml" | grep -q "started by claude" && break
    sleep 1
done
"$OOMGUARD" status -c "$WORK/config.toml" | grep -q "started by claude" || fail "test job never became the candidate"

# 1. Warning stage: the agent is told, nothing is killed.
timeout 5 "$OOMGUARD" run -c "$WORK/config.toml" --simulate occupancy=0.65 > "$WORK/warn.log" || true
grep -q "WARN compressor 65% full" "$WORK/warn.log" || fail "no warning at 65% occupancy"
grep -q "AGENT claude" "$WORK/warn.log" || fail "agent was not messaged"
tmux capture-pane -p -t "$SESSION" | grep -q "\[oomguard\]" || fail "message did not reach the agent's pane"
grep -q "KILL" "$WORK/warn.log" && fail "killed at the warning stage"
pgrep -f "^$WORK/oomguard-e2e-pool" >/dev/null || fail "test job died at the warning stage"

# 2. Kill stage.
timeout 6 "$OOMGUARD" run -c "$WORK/config.toml" --simulate occupancy=0.86 > "$WORK/kill.log" || true
grep -q "KILL .*oomguard-e2e-pool \[occupancy >= 85%" "$WORK/kill.log" || fail "test job was not killed at 86% occupancy"
! pgrep -f "^$WORK/oomguard-e2e-pool" >/dev/null || fail "test job survived"
tmux has-session -t "$SESSION" 2>/dev/null || fail "agent pane died with the job"
# Each run is a fresh guard, so the kill run warns again before its two strikes are up.
[ "$(tr '\n' ' ' < "$WORK/hooks.log")" = "warn agent claude warn agent claude pre_kill post_kill " ] || fail "hooks: $(tr '\n' ' ' < "$WORK/hooks.log")"
[ "$(grep -c . "$XDG_STATE_HOME/oomguard/samples.tsv")" -ge 8 ] || fail "recorder wrote too few samples"
grep -q "KILL" "$XDG_STATE_HOME/oomguard/events.log" || fail "kill missing from the event log"

# 3. Kernel-enforced cap: 300MB under a 100MB cap dies by SIGKILL; under a 1GB cap it lives.
set +e
"$OOMGUARD" exec --max-gb 0.1 -- "$WORK/oomguard-e2e-pool" 1 300 2>/dev/null; capped=$?
timeout 3 "$OOMGUARD" exec --max-gb 1 -- "$WORK/oomguard-e2e-pool" 1 300 2>/dev/null; roomy=$?
set -e
[ "$capped" = 137 ] || fail "process over its cap exited $capped, expected 137 (SIGKILL)"
[ "$roomy" = 124 ] || fail "process under its cap exited $roomy, expected 124 (still running at timeout)"

echo "PASS: warned and messaged the agent, killed the test job at the threshold, ran all hooks,"
echo "      recorded samples and events, agent survived, and the kernel enforced exec --max-gb"
