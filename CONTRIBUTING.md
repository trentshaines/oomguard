# Contributing

```sh
make test          # unit tests (Swift Testing)
scripts/e2e.sh     # real signals, tmux and hooks against a throwaway 3GB job (needs tmux and clang)
make build         # release binary in .build/release/oomguard
```

The policy lives in `Engine` and is a pure function of time, pressure and the current
candidate, so escalation changes should come with a fake-clock test in `EngineTests`.
`Jobs` turns a process table into candidates and is tested against a recorded crash
(`JobsTests.crash`). Only `System` and `Runner` touch the machine.
