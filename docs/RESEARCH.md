# What actually crashes a Mac out of memory, and what a userspace killer can do about it

Research behind oomguard's design, October 2026. Sources: XNU `xnu-12377.101.15` /
`xnu-12377.121.6` (macOS 26.4), Apple's libdispatch and system_cmds, Chromium and Firefox
source, crash reports in public bug trackers, the Linux/Android OOM-killer ecosystem, and
[fl4p/macos-oom-guard](https://github.com/fl4p/macos-oom-guard), whose author logged 82,317
samples and documented each time their guard failed. Measurements are from a 24 GB Apple
Silicon Mac on macOS 26.4.

Labels: **[source]** read in source code or official docs; **[measured]** observed on the test
Mac; **[report]** from a bug report or another project's logs; **[inference]** our reasoning.

## Summary

1. **Neither of macOS's memory-pressure numbers can be trusted as a trigger.**
   `kern.memorystatus_vm_pressure_level` (normal/warn/critical) ignores swap entirely and can
   read *normal* while the machine thrashes. `kern.memorystatus_level` counts active memory as
   "available" and has been observed at 15–20% at the moment of a kernel kill and before a panic.
   On the test Mac, with 12.8 GB of swap in use, the two read **normal** and **72%**.
2. **The cliff is the compressor's segment limit (or the disk), and it is directly measurable.**
   At 98% of `vm.compressor.segment.limit` (or of the compressed-page limit), or when swap can't
   grow, the kernel declares memory exhausted. Panic logs of memory crashes show
   `100% of segments limit (BAD)`. Both are readable without root.
3. **The kernel will not kill your runaway job.** On release macOS kernels, exhaustion kills only
   idle-band daemons; a normal process dies only if it alone holds more than 50% of all compressed
   memory. A pool of ten similar workers never qualifies, so the Mac shows "out of application
   memory" and then panics when WindowServer stalls. Apple's own thrashing detection is compiled
   out on Apple Silicon Macs.
4. **Every userspace killer that waited too long failed.** systemd-oomd's 20–30 s windows lost to
   fast hogs; fl4p's guard was CPU-starved or jetsam-killed in the final minutes. Memory can fill
   at several GB/s and a regrowing worker reached 20 GB in about 20 s. Act early, on rates and
   headroom, not on a sustained-pressure timer.
5. **A guard can protect itself better than fl4p's did, without root.** The compressor-shortage
   kill only targets jetsam band 0; a process can re-exec itself into a higher band with a private
   but exported spawn attribute. Data (not code) can be `mlock`ed. And the kernel itself can
   enforce a fatal per-process memory cap set at spawn time, which works even if the guard is
   starved.
6. **Prevention beats killing.** Kernel-enforced memory caps on jobs you launch, and keeping disk
   free (it is the swap ceiling), remove the crash scenario instead of racing it.

## 1. The two pressure numbers

### `kern.memorystatus_vm_pressure_level` (what Activity Monitor graphs)

**[source]** Computed in `vm_pressure_response()` (`osfmk/vm/vm_pageout.c`). It compares two
quantities (`osfmk/vm/vm_page.h`):

```c
AVAILABLE_NON_COMPRESSED_MEMORY = active + inactive + free + speculative   // "ANC"
AVAILABLE_MEMORY                = ANC + compressor-resident pages           // "AM"
```

With macOS's divisors for machines over 3 GB, the transitions are:

| Transition | Condition |
|---|---|
| normal → warn | ANC < 50% of AM |
| warn → normal | ANC > 60% of AM |
| → critical | ANC < 34.3% of AM, **or** compressor ≥ 98% of either limit |
| critical → warn | ANC > 40% of AM |
| (swapper starts) | ANC < 40% of AM |

Swap appears nowhere. Swapping compressor segments to disk *removes* compressed pages from AM,
which raises the ratio; pages swapped back in become active, which raises ANC. **[inference]** So
a machine churning swap can sit at warn or even normal. Wired memory (e.g. GPU/MLX buffers) is in
neither term, so wiring exhaustion never moves it (an MLX panic report shows
`memoryPressure: false` with 80 GB wired and 0.01 GB free **[report]**).

**[measured]** ANC/AM was 62% (normal) with 7.9 GB swapped; later normal again with 12.8 GB.

Other software agrees it is a weak signal: Chromium skips the warn level by feature flag because
"the 'warn' level signal from the OS is not always an accurate or useful signal", and Firefox only
acts on critical **[source]**. Android abandoned `vmpressure`, a similar bucketed signal, for
PSI after measuring roughly ten times more false positives **[report]**.

### `kern.memorystatus_level` (what macos-oom-guard uses)

**[source]** Also set in `vm_pressure_response()`:

```c
memorystatus_level = ANC * 100 / total_physical_pages;
```

It is not free memory: active anonymous pages, which is exactly what a runaway job's memory is,
count as "available". On macOS no kill threshold is compared against it. `memory_pressure -Q`
prints the same number as "free percentage".

**[report]** It has a floor while the machine dies: 16–35% while swapping on a 16 GB M4, about
18% when a 256 GB Mac Studio's guard failed to fire before a panic, about 20% before fl4p's own
2026-08-26 panic, and never below 9 across fl4p's 82,317 samples. fl4p's README describes it as
falling smoothly to the cliff; their own data contradicts that.

**[measured]** 51–72% on the test Mac across a day with 8–13 GB of swap in use.

## 2. Where the cliff actually is

### Compressor limits **[source]** (`osfmk/vm/vm_compressor.c`)

- `compressor_pool_size` = 4 × RAM for 8–32 GB Macs (2 × above 32 GB, capped at 192 GB).
- `vm.compressor.segment.limit` = pool size / 80 KiB segment allocation (1,211,603 on 24 GB).
- `vm.compressor.pages_compressed_limit` = segments × 8 pages (9,692,824 on 24 GB).
- **Both counts include data swapped out to disk.** They cap total paged-out anonymous memory,
  not RAM. The segment cap here is about 74 GiB of compressed data.
- `vm_compressor_low_on_space()`: either count above **98%**. This forces critical pressure, marks
  the compressor `BAD` in panic logs, and starts the kernel's no-paging-space response.
- `vm_compressor_out_of_space()`: either count at 100%. Compression fails; pages cannot be
  reclaimed; threads block on page faults.

Which limit binds first depends on compressibility: incompressible data fills segments before
pages (a 16 GB M2 Pro panic log: `56% of compressed pages limit (OK) and 100% of segments limit
(BAD) with 42 swapfiles` **[report]**).

### Swap limits **[source]** (`vm_compressor_backing_store.c`)

- At most **100 swap files** of up to 1 GB, about 100 GB.
- Swap is "low" when free swap segments drop below about 32 MB **and** a new swap file couldn't be
  created (disk full) or all 100 exist.
- **[measured]** The test Mac's data volume is 97% full with 61 GiB free, so its real swap ceiling
  is about 61 GB, not 100.

### The panic itself

The panic log line is `Compressor Info: X% of compressed pages limit (OK|BAD) and Y% of segments
limit (OK|BAD) with N swapfiles and OK|LOW swap space` (`osfmk/kern/debug.c`). BAD means above
98%. **[inference, watchdogd is closed source]** With nothing killable, WindowServer and
watchdogd stall on page faults, miss their check-ins for about 90–120 s, and the userspace
watchdog panics the machine. A panic with compressor OK/OK is a pure thrash stall, or not memory
at all: one Codex report was a WindowServer panic caused by 500+ helper processes exhausting
launchservicesd threads **[report]**.

## 3. What the kernel does near the cliff

**[source]** `memorystatus_pick_action()` (`bsd/kern/kern_memorystatus_policy.c`), macOS release:

1. Zone map exhausted (kernel memory) → kill the top process in any band.
2. Compressor or swap **exhausted** → kill the top process only if `kill_on_no_paging_space`,
   which is hard-coded `false` on release kernels.
3. Compressor or swap **low (98%)** → kill idle-band (band 0) processes, reason
   `vm-compressor-space-shortage`. When none are left, `no_paging_space_action()` at most every
   5 s: SIGKILL the largest process **only if it holds more than 50% of all compressed pages**;
   otherwise act on a process that opted in via `proc_setpcontrol()`; otherwise post the
   "Your system has run out of application memory" dialog.
4. Pressure critical → purge caches, at most once a minute.

Jetsam bands: a process forked from a terminal gets `JETSAM_PRIORITY_DEFAULT` = 180; release
macOS caps memory kills at the idle band, so band-180 jobs survive. Apple Silicon Macs compile out
thrashing detection (`#if (XNU_TARGET_OS_OSX && __arm64__) /* Thrashing detection disabled. */`).

`kern.memorystatus.kill_on_sustained_pressure_*` (present, count 0) kills idle daemons after 10
minutes above normal; enabling it requires a private entitlement or boot-arg, and it would not
help: it keys off the unreliable level and only kills idle daemons **[source]**.

**[inference]** This is why the 2026-10-10 crash happened: ten ~5 GB `worker.py` workers, none
above 50% of compressed memory, so the kernel had no victim.

## 4. How fast it goes

- Linux userspace killers assume RAM can fill at about **6 GB/s** (nohang's default); 1 GB of
  headroom lasts under 200 ms **[source]**.
- A respawned worker regrew to 17–26 GB in about **20 s**; swap rose 3.4 GB in 15 s in another
  report **[report]**.
- fl4p's 2026-08-26 run-up was slow: 2.4 GB of swap over 6 minutes, with their guard starved for
  the last 3 **[report]**.
- After WindowServer stops checking in, the watchdog panics after about 90–120 s **[report]**.
- On Linux, once thrashing starts it lasts 10–30+ minutes without a kill **[report]**.

So both regimes exist: fast fills (seconds) and slow creeps (minutes), and a guard needs to catch
both.

## 5. Lessons from the guards that failed

### fl4p/macos-oom-guard (Python, root LaunchDaemon) **[report, self-documented]**

| Failure | Cause | Lesson |
|---|---|---|
| Swap trigger never fired in 82k samples | Threshold (1.5 × RAM) above anything ever reached | Calibrate triggers against real data; absolute swap doesn't discriminate (40 GB swap was normal there) |
| Oscillating burst never armed | One clean sample reset the strike count | Leaky-bucket confirmation, not reset-on-clean |
| Silent through a panic (2026-08-26) | Guard not scheduled for its last 3 minutes, despite root and nice −20 | Act minutes early; a guard on the contended resource can't referee it at the end |
| Killed 5 workers, still panicked (2026-10-04) | Pool respawned each killed worker; it regrew in 20 s | Kill the whole group/family, not the biggest process |
| Guard killed by jetsam (2026-10-04) | Guard was in band 0, which `vm-compressor-space-shortage` targets | Get out of band 0 |
| `mlockall` silently failed for months | macOS returns ENOSYS; ctypes ignores −1 | Check every syscall result |

### Linux and Android **[source/report]**

- **The kernel OOM killer fires too late**: reclaim keeps "making progress" by evicting and
  refaulting file pages, so systems thrash for 30+ minutes without a kill (Facebook, Fedora).
- **Free-memory thresholds fail** (earlyoom): the AND of MemAvailable% and SwapFree% fires late
  or never; a buggy kernel estimate (#320) or compressed swap (zram, #71) defeats it. The macOS
  compressor is the zram analogue: count it as used, and discount swap headroom (ChromeOS counts
  only a quarter of free swap).
- **Measure the cost of the shortage, not the amount**: PSI (time stalled on memory) replaced
  free-memory heuristics at Meta, systemd and Android (~10× fewer false positives than vmpressure).
  macOS has no PSI; the closest proxies are swap-in, decompression and pagein rates.
- **Long windows lose to fast hogs**: systemd-oomd's 20–30 s windows let the kernel OOM-kill
  first in Fedora's test week. Android's lmkd uses 1 s windows and 10 ms polling under pressure.
- **Grouping cuts both ways**: killing one PID loses to respawning pools; killing a coarse group
  (systemd-oomd killed whole desktop sessions and every terminal tab sharing a scope) kills the
  innocent. Process groups are a good default on macOS because shells and coding agents give each
  command its own; app bundles keep helpers in one group.
- **One kill in flight**: every project hit the double-kill bug (earlyoom #128). Wait for the
  victim to exit (macOS: `kqueue` `EVFILT_PROC`/`NOTE_EXIT`), escalate SIGTERM to SIGKILL after a
  short timeout, then re-measure before choosing another victim.
- **Hot-loop hygiene**: all mature killers lock their memory and avoid forking, allocating or
  scanning command lines on the critical path; lmkd runs at realtime priority and kills from a
  separate thread.
- **Victim ranking**: self-assigned priorities can dominate (Chrome/Electron `oom_score_adj`,
  earlyoom #261). Rank by footprint and growth; give users prefer/avoid/never lists.

## 6. What a userspace guard on macOS can do to survive **[source, measured]**

| Technique | Without root? | Effect |
|---|---|---|
| Re-exec into jetsam band 180–210 via `posix_spawnattr_setjetsam_ext` + `POSIX_SPAWN_SETEXEC` | Yes (private, exported API; tested) | Escapes `vm-compressor-space-shortage` kills, which only take band 0 |
| `ProcessType=Interactive` in the plist | Yes | Base priority 31, but jetsam band only 40 (measured) |
| `mlock` preallocated data | Yes (up to ~18 GB wire limit) | Keeps data resident; code pages can't be locked (EPERM) |
| Realtime thread (`THREAD_TIME_CONSTRAINT_POLICY`) | Yes (tested) | Stays scheduled; doesn't help while blocked on a page fault |
| `setpriority` below 0 | No | — |
| `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` | Yes, but… | Skips processes under 10 MB footprint; 25 s rest between rounds. Root "privileged listeners" are notified first |
| `NOTE_MEMORYSTATUS_LOW_SWAP` | Yes | Broadcast to all registered processes at the "out of application memory" stage: a last-resort trigger |
| `SET_PRIORITY_PROPERTIES`, `SET_MEMLIMIT_PROPERTIES` via `memorystatus_control` | Root only | Raise own band; put a fatal memory limit on any running process |

**Kernel-enforced caps (prevention).** A fatal per-process memory limit is enforced by the kernel
at allocation time, so it needs no userspace scheduling. Without root, it can be set on a child at
spawn (`posix_spawnattr_setjetsam_ext` with `MEMLIMIT_*_FATAL`): a child capped at 64 MB was
killed with reason `per-process-limit` **[measured]**. The cap is per process and not inherited by
grandchildren, so a worker pool escapes it unless each worker is capped. `proc_setpcontrol
(PROC_SETPC_TERMINATE)` in a child marks it as a kernel no-paging-space victim. `setrlimit` does
not help: `RLIMIT_AS`/`RLIMIT_DATA` cap address space (which breaks runtimes) and `RLIMIT_RSS` is
not enforced.

Not reachable by a userspace killer at all: wired GPU memory (cap `iogpu.wired_limit_mb`
instead), kernel zone leaks, and WindowServer panics with non-memory causes.

## 7. What oomguard does about it

v0.1 triggered on 30 s of continuous critical `memorystatus_vm_pressure_level`: the wrong signal
(section 1) on the wrong time scale (section 4). It failed in the field on 2026-10-11: the level
flickered between critical and warn for nine minutes, resetting the timer each time, and the
final critical run froze the Mac in about 14 s. v0.2 implements the following; v0.2.1 adds the tight-memory gate.

**Signals** (sysctls and `statfs`, readable without root, no subprocess):

| Signal | Source | Role |
|---|---|---|
| Occupancy = max(segments, pages) / limit | `vm.compressor.segment.*`, `vm.compressor.pages_compressed*` | Distance to the cliff (kernel acts at 98%) |
| Swap headroom = min(free disk on `/System/Volumes/VM` + unused swapfile space, 100 GB − swap used) | `statfs`, `vm.swapusage` | Second cliff; the binding one on a full disk |
| Time to full = (98% − occupancy) / fill rate over ~10 s | derived | Catches fast fills while occupancy is still moderate |
| Pressure level | `kern.memorystatus_vm_pressure_level` | Backstop arm only |
| Free memory, `kern.memorystatus_level` | sysctl | Gates the occupancy and time-to-full arms (v0.2.1, from the fill test below) |
| Swap-in rate | sysctl | Recorded, not yet acted on |

**Policy** (`Engine`, a pure function of the samples; defaults are configurable):

- **Warn** at 60% occupancy, under 5 minutes to full, or headroom below RAM size: notify, and
  message the agent that owns the biggest job.
- **Kill** immediately at 92% occupancy or under 2 GB of headroom; after 2 strikes at 85%, under
  60 s to full (from half full), or under 4 GB of headroom; after 10 strikes of critical pressure.
- **Leaky-bucket strikes**: +1 per tripping sample, −0.5 per clean one, so a flickering signal
  accumulates (fl4p's and our own failure).
- **One kill in flight**: SIGSTOP the process group (instant, needs no memory), SIGKILL it, wait
  for it to exit, then only the immediate arms may fire for a settle period.
- A gap between samples is logged as a stall and never read as a fill rate.
- **Occupancy only counts while memory is tight** (free memory ≤ 40% or pressure above
  normal). Empty compressor segments are freed lazily, so after a crunch occupancy can sit near a
  kill threshold with RAM free again; without the gate each kill would be followed by kills of
  innocent jobs. Swap headroom and pressure arms are not gated.

**Recorder**: every sample to `samples.tsv` (synced every 10 s and on every event), warnings and
kills with their reasons to `events.log`.

**Guard survival**: at startup the guard re-executes itself into jetsam band 180 with
`posix_spawnattr_setjetsam_ext`. A LaunchAgent with `ProcessType=Interactive` otherwise sits in
band 40 (measured); the compressor-shortage kill only takes band 0. Whether launchd later resets
the band is not verified (reading a process's band needs root).

**Prevention**: `oomguard exec --max-gb N -- cmd` starts a command under a fatal per-process
memory limit; the kernel kills it at the limit with no help from userspace (verified by the
end-to-end test).

**Not done**, and why: `mlock` of the guard's data and a realtime sampling thread (unmeasured
benefit; code pages cannot be locked anyway); acting on swap-in rate (no calibration data yet);
a root helper to cap or resume already-running processes (trust cost). The thresholds are first
guesses: the recorder exists to calibrate them.

### Controlled fill test, 2026-10-25 **[measured]**

`scripts/fill-test.sh` on a 64 GB Mac mini (macOS 27): an 8-worker pool writing incompressible
data at 1.5 GB/s, against a test guard set to kill 4–5 points above the starting occupancy. Every
other job was protected by a `never` rule, and the installed guard kept running at its defaults.

| Second | Segments | Pages | Free memory | Pressure |
|---|---|---|---|---|
| 0 | 16.5% | 7.8% | 67% | normal |
| 1 | 18.6% | 8.6% | 63% | normal |
| 2 | 28.2% | 11.0% | 48% | normal |
| 3 | 30.7% | 12.1% | 41% | warn |
| 4 | 34.0% | 13.0% | 36% | warn: killed (22 GB pool) |

- **Occupancy moves fast once RAM is full**: up to 10 points in one second, much faster than the
  pool's own rate, because the kernel compresses other apps' pages at the same time. Two strikes
  at a threshold can therefore land a few points past it; the 92% immediate arm leaves 6 points
  below the kernel's 98%.
- **Segment occupancy is sticky.** 20 s after the kill free memory was back at 65% and pressure
  normal, but segment occupancy stayed at 34% (42% after a second run) while page occupancy fell
  back to 8%. It stayed near 40% for 34 hours, then dropped from 38% to 12% between two
  one-second samples with 84% of memory free. The kernel compacts segments when it needs them: one run started at 24.5% and dropped
  to 16.5% as the new fill began. Hence the tight-memory gate above.
- **Segments, not pages, are the binding limit** for incompressible data: pages occupancy never
  passed 13%.
- The guard's 1 s sampling never stalled, and the installed guard warned through the agent
  channel (it typed into the owning Claude Code session's tmux pane) before the test guard
  killed. Free memory (`memorystatus_level`) fell 67% → 36% in 4 s, so the gate opens early in a
  real fill.

## 8. Open questions and experiments

- A fill test with compressible data (2–3:1, like Python objects) on a 24 GB Mac, run to the
  default 85%. That is the case the defaults are tuned for and it has not been measured.
- Does launchd honor `JetsamProperties` in a third-party plist? Does it reset a band the guard
  raised itself?
- Can a non-root guard cap a *running* process (not just a child it spawns)? Root can
  (`SET_MEMLIMIT_PROPERTIES`); is a root helper worth the trust cost?
- Exact behaviour of `NOTE_MEMORYSTATUS_LOW_SWAP` timing relative to the panic.

## Sources

- XNU: https://github.com/apple-oss-distributions/xnu (tags `xnu-12377.101.15`, `xnu-12377.121.6`):
  `osfmk/vm/vm_pageout.c`, `osfmk/vm/vm_page.h`, `osfmk/vm/vm_compressor.c`,
  `osfmk/vm/vm_compressor_backing_store.c`, `bsd/kern/kern_memorystatus*.c`,
  `bsd/kern/kern_proc.c`, `bsd/kern/kern_exec.c`, `bsd/kern/kern_mman.c`, `osfmk/kern/debug.c`,
  `doc/vm/memorystatus*.md`
- fl4p/macos-oom-guard: https://github.com/fl4p/macos-oom-guard (module docstring revisions
  2026-08-27 and 2026-10-04, tests)
- Crash reports: microsoft/power-platform-skills#464, rajeshgoli/session-manager#2053,
  anthropics/claude-code#24960, #88273, #44824, ml-explore/mlx-lm#883, openai/codex#38760,
  #46262, daintreehq/daintree#12799, mcclowes/turnstile#17; Apple DTS on watchdog panics:
  https://developer.apple.com/forums/thread/774651
- Chromium `components/memory_pressure/system_memory_pressure_evaluator_mac.cc`; Firefox
  `xpcom/base/AvailableMemoryWatcherMac.cpp`
- Linux/Android: https://docs.kernel.org/accounting/psi.html, https://lwn.net/Articles/759658/,
  https://lwn.net/Articles/865341/, https://lwn.net/Articles/668126/,
  https://github.com/rfjakob/earlyoom (#128, #261, #320, #71),
  https://man.archlinux.org/man/oomd.conf.5, https://fedoraproject.org/wiki/Changes/EnableSystemdOomd,
  https://bugzilla.redhat.com/show_bug.cgi?id=1933494, https://bugs.launchpad.net/bugs/1985887,
  https://engineering.fb.com/2018/07/19/production-engineering/oomd/,
  https://github.com/facebookincubator/oomd, https://github.com/hakavlad/nohang,
  https://source.android.com/docs/core/perf/lmkd,
  https://www.chromium.org/chromium-os/chromiumos-design-docs/out-of-memory-handling/
