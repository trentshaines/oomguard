# oomguard

> **Beta.** Tested with simulated readings, a real memory fill on a 64GB Mac mini, and CI on
> macOS 14 and 15 (Apple Silicon and Intel). Thresholds are first estimates; run it with
> `--dry-run` for a while if you want to see what it would do before trusting it.

An early OOM killer for macOS, in the spirit of [earlyoom] and [systemd-oomd].

When a job asks for more memory than a Mac has, macOS does not kill it. It compresses memory,
grows swap, pauses your apps behind a "Your system has run out of application memory" dialog,
and then freezes until a watchdog reboots it. Its own killer only takes a process that alone
holds over half of all compressed memory, so a job spread over several worker processes is
never chosen.

oomguard watches the thing the kernel actually runs out of and kills the biggest job a few
seconds before that happens. If a coding agent (Claude Code, Codex) started the job, the agent is
warned first, while there is still time for it to fix things itself.

## How it works

Once a second, straight from the kernel (no subprocesses):

| Reading | What it is | Why |
|---|---|---|
| **Occupancy** | How full the memory compressor is: segments or pages used ÷ limit | Counts memory in RAM *and* swap. At 98% the kernel declares memory exhausted; memory-crash panic logs read `100% of segments limit (BAD)`. |
| **Headroom** | Room left for swap: free disk + unused swapfile space, capped at macOS's 100 GB of swapfiles | Swap can't outgrow the disk. A nearly full disk is a much lower ceiling. |
| **Time to full** | Seconds until occupancy reaches 98% at the last 10 s fill rate | Catches a fast fill while occupancy is still moderate. |
| **Pressure level** | The kernel's normal/warn/critical level | Backstop only: it ignores swap and flickers. |
| **Free memory** | `kern.memorystatus_level`, the % of memory available | Gates the compressor triggers: the kernel frees empty segments lazily, so occupancy stays high after a crunch while RAM is free again. |

```
warn    occupancy ≥ 60%, full in < 5 min, or headroom < RAM size
        → notification, and a message typed into the tmux pane of the agent that owns the biggest job

        (occupancy and "full in" count only while free memory ≤ 40% or pressure is raised)

kill    occupancy ≥ 92% or headroom < 2 GB                      immediately
        occupancy ≥ 85%, full in < 60 s, or headroom < 4 GB     after 2 seconds
        critical pressure                                        after 10 accumulated seconds
        → SIGSTOP then SIGKILL the biggest job, wait for it to exit, let memory settle
```

- **A job is a process group.** Shells, Claude Code and Codex start every command in its own
  group, so a ten-worker pool is one job, separate from the agent that launched it. One signal
  reaches every worker, including detached ones, so a pool can't respawn its way past the kill.
- **Size is `phys_footprint`**, Activity Monitor's "Memory" column, which still counts pages
  macOS has compressed or swapped out.
- **Strikes leak, they don't reset.** A reading that trips a trigger adds a strike; a clean one
  removes half. A flickering signal still adds up. (Requiring continuous pressure is how a Mac
  froze with an earlier version of this guard watching.)
- **It runs as you, never as root,** and only considers your processes. Terminals, tmux, Finder
  and the Dock are never killed; `prefer`, `avoid` and `never` rules adjust the rest.
- **Everything is recorded.** One line per second in `~/.local/state/oomguard/samples.tsv`, and
  every warning and kill with its reason in `events.log`. A gap in the samples means the guard
  itself was not running.

Why these signals and not "memory pressure" or "free memory": [docs/RESEARCH.md](docs/RESEARCH.md).

## Install

```sh
brew install trentshaines/tap/oomguard
brew services start oomguard
```

From source (needs Swift 6 from Xcode or the Command Line Tools):
`make install-service PREFIX=~/.local` builds it, installs the binary and loads a launchd agent
that starts it at login. `make uninstall PREFIX=~/.local` removes both.

`oomguard status` says whether the guard is running; `sudo oomguard status` also shows the jetsam
band it is in (reading it needs root).

Try it before trusting it:

```sh
oomguard status          # readings, biggest jobs, and which one would be killed
oomguard run --dry-run   # watch for real, but only log what would be killed
oomguard log             # recent events;  oomguard log --samples  for the per-second readings
```

## Prevent instead of kill

```sh
oomguard exec --max-gb 16 -- python3 train.py
```

runs a command under a memory cap enforced by the kernel itself: the process is killed the
moment its footprint passes the cap, even if everything else is frozen. The cap is per process
and is not inherited, so a worker pool needs each worker started this way.

Two other things that matter more than any killer: keep free disk space above your RAM size
(it is your swap ceiling), and limit worker counts to what the machine can hold.

## Configure

Optional, at `~/.config/oomguard/config.toml`. Every key and its default is in
[`config.example.toml`](config.example.toml). For example:

```toml
[trigger]
kill_occupancy = 0.80            # act earlier

[victim]
prefer = ["make_dataset\\.py"]   # known memory hogs die first
avoid = ["OrbStack"]             # Docker goes last

[hooks]
post_kill = "say 'oomguard killed a job'"
```

`oomguard config` validates the file and prints the effective settings. Flags override it:
`--dry-run`, `--min-size-gb`, `--interval`, `--config`.

To test rules and hooks without a real memory crisis, override a reading:
`oomguard run --dry-run --simulate occupancy=0.9`. Without `--dry-run` the kill is real, so pair
it with a `never` rule that protects everything but a test job, as
[`scripts/e2e.sh`](scripts/e2e.sh) does. [`scripts/fill-test.sh`](scripts/fill-test.sh) goes
further: it really fills memory with a test pool and checks that a guard set a few points above
the current occupancy kills it, on the kernel's own readings. It squeezes your other apps for a
minute, so run it when that's fine.

The default thresholds are starting points. After a tight-memory episode, `oomguard log` and the
samples show how early each trigger fired on your machine; adjust from there.

## Limits

- It cannot kill other users' or root processes, and it cannot free wired GPU memory or kernel
  leaks. Some freezes are not about memory at all.
- Memory spread over many small unrelated jobs, none over `min_size_gb`, leaves nothing to kill.
- Jobs started without job control (e.g. `cmd &` in a non-interactive script) share their
  parent's group; oomguard then kills that whole group.
- The jetsam band move and `oomguard exec --max-gb` use `posix_spawnattr_setjetsam_ext`, a
  private libsystem call that launchd itself uses. It is looked up at run time: if a future macOS
  drops it, oomguard logs that it could not change its band, keeps guarding, and `exec` says it
  cannot cap memory. Everything else uses public interfaces (sysctl, libproc, signals).
- A userspace guard competes for the resource it guards. oomguard is a small native binary that
  acts early and moves itself out of the priority band the kernel's own shortage kill targets,
  but under an extreme fill it can still be starved. `oomguard exec --max-gb` does not have that
  weakness.

## Inspiration and credit

| | Idea | In oomguard |
|---|---|---|
| Linux kernel OOM killer | badness score, `oom_score_adj` | `prefer` / `avoid` / `never` tiers |
| [earlyoom] | act before the kernel does; `--prefer` / `--avoid`; kill the process group | the whole premise |
| [systemd-oomd], [oomd] | measure the cost of the shortage, kill a whole group | process groups, fill-rate trigger |
| [nohang] | config file, notifications, hooks, compressed-swap awareness | TOML config, hooks, occupancy |
| Android lmkd | short windows, wait for the victim before killing again | 1 s sampling, settle period |
| [macos-oom-guard] | months of field notes on how a macOS guard fails | leaky-bucket strikes, group kills, SIGKILL, logging |

## License

MIT

[earlyoom]: https://github.com/rfjakob/earlyoom
[systemd-oomd]: https://www.freedesktop.org/software/systemd/man/latest/systemd-oomd.service.html
[oomd]: https://github.com/facebookincubator/oomd
[nohang]: https://github.com/hakavlad/nohang
[macos-oom-guard]: https://github.com/fl4p/macos-oom-guard
