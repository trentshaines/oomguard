#!/usr/bin/env bash
# A real memory fill, with real kernel readings: no --simulate.
#
# A pool of workers in one process group fills memory with incompressible data at about
# RATE_MB per second, the way a runaway worker pool does. A test guard, set to kill once real
# compressor occupancy is DELTA above where it started, must find and kill the pool. Every
# other job is protected with a `never` rule, so the test guard can only kill the pool.
#
# This is a real memory crunch: other apps get compressed and swapped for a minute. It stays
# far from the kernel's 98% limit. Safeties: the pool stops growing at CAP_GB, the script
# kills the pool itself if occupancy overshoots by MARGIN or the guard hasn't acted within
# TIMEOUT seconds, and the installed guard, if any, keeps watching at its own thresholds.
#
#   DELTA=0.05 RATE_MB=1500 scripts/fill-test.sh
set -euo pipefail

OOMGUARD=${OOMGUARD:-$(cd "$(dirname "$0")/.." && pwd)/.build/debug/oomguard}
DELTA=${DELTA:-0.05}      # kill this far above the starting occupancy
MARGIN=${MARGIN:-0.08}    # the script gives up and kills the pool this far beyond that
RATE_MB=${RATE_MB:-1500}  # pool fill rate, MB/s
WORKERS=${WORKERS:-8}
CAP_GB=${CAP_GB:-$(( $(sysctl -n hw.memsize) / 1073741824 * 3 / 2 ))}
TIMEOUT=${TIMEOUT:-300}
WORK=$(mktemp -d)
export XDG_STATE_HOME=$WORK/state
POOL=$WORK/oomguard-fill-pool

occupancy() {
    local s p
    s=$(sysctl -n vm.compressor.segment.total vm.compressor.segment.limit | paste -sd/ - | bc -l)
    p=$(sysctl -n vm.compressor.pages_compressed vm.compressor.pages_compressed_limit | paste -sd/ - | bc -l)
    echo "if ($s > $p) $s else $p" | bc -l
}
cleanup() {
    [ -n "${GUARD:-}" ] && kill "$GUARD" 2>/dev/null || true
    pkill -KILL -f "$POOL" 2>/dev/null || true
}
trap 'cleanup; echo "state kept in $WORK"' EXIT

cat > "$WORK/pool.c" <<'EOF'
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>
/* pool WORKERS MB_PER_SECOND TOTAL_MB: fork workers that together allocate incompressible
   memory at MB_PER_SECOND until TOTAL_MB, then hold it. */
int main(int argc, char **argv) {
    int workers = atoi(argv[1]);
    size_t rate = atol(argv[2]) / workers, total = atol(argv[3]) / workers, done = 0;
    for (int i = 1; i < workers; i++) if (fork() == 0) break;
    uint64_t x = 88172645463325252ull ^ (uint64_t)getpid();
    while (done < total) {
        struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
        size_t mb = rate / 10 ? rate / 10 : 1;           /* one tenth of a second's worth */
        volatile uint64_t *p = malloc(mb << 20);   /* volatile: the writes must happen */
        for (size_t i = 0; i < (mb << 20) / 8; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; p[i] = x; }
        done += mb;
        clock_gettime(CLOCK_MONOTONIC, &t1);
        long spent = (t1.tv_sec - t0.tv_sec) * 1000000 + (t1.tv_nsec - t0.tv_nsec) / 1000;
        if (spent < 100000) usleep(100000 - spent);
    }
    sleep(600);
    return 0;
}
EOF
clang -O2 -o "$POOL" "$WORK/pool.c"

START=$(occupancy)
KILL_AT=$(echo "$START + $DELTA" | bc -l)
GIVE_UP=$(echo "$KILL_AT + $MARGIN" | bc -l)
cat > "$WORK/config.toml" <<EOF
[trigger]
kill_occupancy = $(printf %.3f "$KILL_AT")
kill_occupancy_now = $(printf %.3f "$(echo "$KILL_AT + 0.05" | bc -l)")
warn_occupancy = $(printf %.3f "$(echo "$START + $DELTA / 2" | bc -l)")
[victim]
min_size_gb = 1
never = ["^(?!.*oomguard-fill-pool)"]
[notify]
enabled = false
[agents]
enabled = false
EOF
printf "occupancy %.1f%% at start; test guard kills at %.1f%%; script gives up at %.1f%%\n" \
    "$(echo "$START * 100" | bc -l)" "$(echo "$KILL_AT * 100" | bc -l)" "$(echo "$GIVE_UP * 100" | bc -l)"
echo "pool: $WORKERS workers, ${RATE_MB}MB/s together, at most ${CAP_GB}GB"

"$OOMGUARD" run -c "$WORK/config.toml" > "$WORK/guard.log" 2>&1 &
GUARD=$!
sleep 2

set -m   # the pool gets its own process group, led by the pool binary
"$POOL" "$WORKERS" "$RATE_MB" $(( CAP_GB * 1024 )) &
set +m
T0=$(date +%s)

result=timeout peak=$START
while [ $(( $(date +%s) - T0 )) -lt "$TIMEOUT" ]; do
    now=$(occupancy)
    [ "$(echo "$now > $peak" | bc -l)" = 1 ] && peak=$now
    if grep -q "KILL" "$WORK/guard.log"; then result=killed; break; fi
    if [ "$(echo "$now > $GIVE_UP" | bc -l)" = 1 ]; then result=overshoot; break; fi
    if ! pgrep -f "$POOL" >/dev/null; then result=pool-died; break; fi
    sleep 0.5
done
ELAPSED=$(( $(date +%s) - T0 ))

if [ "$result" = killed ]; then
    for _ in $(seq 20); do pgrep -f "$POOL" >/dev/null || break; sleep 0.5; done
    pgrep -f "$POOL" >/dev/null && result=survived
fi
cleanup
GUARD=

# Let memory settle and see how fast occupancy comes back down.
RECOVERED=no
for i in $(seq 60); do
    if [ "$(echo "$(occupancy) < $KILL_AT" | bc -l)" = 1 ]; then RECOVERED="${i}s"; break; fi
    sleep 1
done

echo
grep -E "WARN|KILL|STALL|pressure" "$WORK/guard.log" || true
printf "\npeak occupancy %.1f%%, guard acted after %ss, back under the kill line after %s\n" \
    "$(echo "$peak * 100" | bc -l)" "$ELAPSED" "$RECOVERED"
echo "per-second readings: $XDG_STATE_HOME/oomguard/samples.tsv"
case $result in
    killed) echo "PASS: the guard killed the pool on real readings" ;;
    *) echo "FAIL: $result"; exit 1 ;;
esac
