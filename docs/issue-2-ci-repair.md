# Issue #2 CI-repair notes (simulator stalls)

Issue #2 functional evidence lives in the PR #9 description and will only be
claimed from a green CI run at the exact head with retained `ios-ci-<sha>`
artifacts. This file records the CI-environment repairs so the next session
does not re-diagnose fixed stalls.

## Measured failures (head `abbc35e` and earlier `2d6eade`)

All failures happened in the simulator-selection/boot phases; toolchain
selection, helper tests, and (where reached) domain tests passed.

| Run (attempt) | Head | Failing command | Evidence |
|---|---|---|---|
| 35284855408 | 2d6eade | `xcrun simctl list devices available --json` | timed out after 30s (select_simulator.py) |
| 35400483186 a1 | abbc35e | `xcrun simctl bootstatus <UDID> -b` | timed out after 180s (boot_simulator.py) |
| 35400483186 a2 | abbc35e | `xcrun simctl bootstatus <UDID> -b` | timed out after 180s |
| 35400483186 a3 | abbc35e | `xcrun simctl list devices available --json` | timed out after 30s |

This is the same wedged-CoreSimulator stall class measured in the seat-weave
lane (PR #8/#9, 2026-09-16); reruns alone were not the answer there either.

## Repair (head `815c150`)

Ported from the proven seat-weave repair, adapted to this repo:

- `Scripts/select_simulator.py`
  - `enumerate_available_devices()` retries `simctl list devices available
    --json` exactly once on `TimeoutExpired` (nonzero exit is a real
    environment error and is NOT retried).
  - `SPLITSIP_SIMCTL_TIMEOUT_SECONDS` env override (guard: non-integer or
    <=0 falls back to the 30s default) so regression tests run in seconds.
  - The devices JSON file is `flush()`ed immediately after writing: a caught
    `TimeoutExpired` keeps the write handle's frame alive, and interpreter-exit
    finalization alone could leave the file empty and crash the boot phase
    with empty JSON (seat-weave proved this with a fake-xcrun subprocess).
- `Scripts/boot_simulator.py`
  - `SimulatorBootError` carries a `timed_out` flag.
  - A boot/bootstatus **timeout** on a not-yet-booted simulator triggers one
    best-effort `simctl shutdown` (failures/timeouts logged and tolerated),
    then exactly one boot+bootstatus re-attempt. A second timeout or any
    non-timeout error remains fatal. All timeout budgets unchanged
    (boot 120s, bootstatus 180s).
- Regression tests in `Scripts/tests/`: retry call-sequence
  (`boot, bootstatus, shutdown, boot, bootstatus`), no-second-retry,
  tolerated shutdown failure, and a subprocess-level fake-xcrun CLI probe
  asserting the devices JSON is non-empty after a stalled first attempt.

Host verification at head `815c150` (Linux, not native-build evidence):
`python3 -m unittest discover -s Scripts/tests -v` — 21 tests OK;
`swift test` for `Packages/ReceiptDomain` (Docker `swift:6.1`) — 40 tests
passed; `bash -n Scripts/ci.sh` clean. No production app code changed.
