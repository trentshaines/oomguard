# Changelog

## 0.2.1 (2026-10-25)

- Occupancy and time-to-full triggers count only while memory is tight (free memory at or below
  `trigger.tight_free_ram`, default 40%, or pressure above normal). Found with a real memory fill:
  the kernel keeps empty compressor segments around, so occupancy stays high after a crunch while
  RAM is free again, which would have led to kills of innocent jobs.
- `scripts/fill-test.sh`: a real memory fill against a test guard, on the kernel's own readings.
- The private `posix_spawnattr_setjetsam_ext` is looked up at run time: on a macOS without it the
  guard still runs (and logs that it could not change its band) instead of failing to launch.
- The guard logs the jetsam band it ended up in. `oomguard status` shows whether a guard is
  running and, as root, its band.
- `--simulate free-ram=N`; `--simulate occupancy=N` also simulates low free memory.
- CI on macOS 14, macOS 15 and Intel, including the end-to-end test.
- Homebrew formula no longer requires full Xcode.

## 0.2.0 (2026-10-12)

First release: compressor occupancy, swap headroom, time to full and pressure triggers with
leaky-bucket strikes; process-group kills; agent warnings through tmux; hooks; recorder;
`oomguard exec --max-gb`.
