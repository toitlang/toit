# Hardware ("serial") tests

This directory contains tests that run on real hardware. This document
describes how to run the ESP32 tests against attached boards, and how to
reproduce failures from the daily `serial` CI job locally.

## Overview

The "serial" tests are CTest fixtures that drive real ESP32 boards over USB.
The CI workflow runs them on a self-hosted runner (label `serial`) once a day
from `.github/workflows/ci.yml` (job `serial`). Locally you can reproduce them on
any Linux machine with the boards plugged in.

The tests live in two trees:
- [`pi/`](pi/) — Raspberry Pi tests. Skip locally unless you actually have a Pi.
- [`esp32/`](esp32/) — ESP32 / ESP32-S3 board tests. These are the ones the
  daily CI runs.

The driver is [`esp-tester/tester.toit`](esp-tester/tester.toit). It flashes a
per-test firmware onto the board, runs the test program, and collects output
back over the serial line.

## Prerequisites

1. **Built host SDK** at `build/host/sdk/bin/toit`. If you change SDK code, run
   `make sdk` to rebuild it.
2. **Built ESP32 firmware envelope** at `build/esp32/firmware.envelope`
   (and `build/esp32s3/firmware.envelope` if testing s3).
   Build with `make esp32` and `make esp32s3` respectively.
3. **Boards plugged in**, accessible at the udev paths in `esp32-test.env`:
   `/dev/ttyEsp32Board1`, `/dev/ttyEsp32Board2`, `/dev/ttyEsp32s3Board1`,
   `/dev/ttyEsp32s3Board2`.
4. **`esp32-test.env`** at the repo root with the WiFi credentials and port
   paths.

## Setup

```bash
source esp32-test.env                                  # ports + WiFi creds
export TOIT_EXE_HW=$PWD/build/host/sdk/bin/toit
export ESP32_ENVELOPE=$PWD/build/esp32/firmware.envelope
export ESP32S3_ENVELOPE=$PWD/build/esp32s3/firmware.envelope   # only if you have it
make rebuild-cmake-hw
```

**`ESP32_ENVELOPE` / `ESP32S3_ENVELOPE` are not in `esp32-test.env`** — the CI
workflow sets them separately from a downloaded artifact. You must export them
yourself, otherwise ctest invokes
`toit tool firmware container add … -e "" -o …` and the tester fails
immediately with `Error: Failed to open '' for reading (FILE_NOT_FOUND: "")`.

**Why `make rebuild-cmake-hw` matters.** The CMake test definition embeds the
env-var values into each test's command line at *configure* time
([`esp32/CMakeLists.txt`](esp32/CMakeLists.txt)). Changing `ESP32_ENVELOPE`
after configuration has no effect until you re-run cmake. `rebuild-cmake-hw`
deletes `build/hw/CMakeCache.txt` and re-configures.

## Running tests

`ctest -C <config>` selects which tests to run. The CMakeLists tags every test
with the configurations `<variant>` and `hw`, so:

| `-C` value | Runs |
|---|---|
| `-C esp32` | Only esp32 tests (skip esp32s3 setup fixtures) |
| `-C esp32s3` | Only esp32s3 tests |
| `-C hw` | Both — what CI uses |

Run a single test:

```bash
ctest --verbose --test-dir build/hw -C esp32 -R "bme280-board1.toit-esp32$"
```

Run a category:

```bash
ctest --verbose --test-dir build/hw -C esp32 -R "uart-"
```

Notes:
- `-R <regex>` matches test names. Append `$` to avoid matching the `-esp32s3`
  variant when you want only esp32.
- `--verbose` prints stdout from the tester (firmware flash log, board output,
  exception traces). Without it you only see PASS/FAIL.
- If a test matches but its `setup-board*-<variant>` fixture isn't selected
  (wrong `-C`), the test reports **Not Run** with
  `Failed test dependencies: setup-board…`. That is not the same as a real
  test failure.

## Typical failure modes

- **`FILE_NOT_FOUND: ""`** in the setup test → you forgot `ESP32_ENVELOPE` or
  didn't re-run `make rebuild-cmake-hw` after setting it.
- **All esp32s3 tests Not Run** → `build/esp32s3/firmware.envelope` is missing.
  Either build it (`make esp32s3`) or run with `-C esp32` to skip.
- **Setup `Timeout` on board1/board2** → board not responding on its USB port.
  Re-plug, check `ls -l /dev/ttyEsp32*`, or look at `dmesg | tail`.
- **Test runs but throws on the board** (e.g. `INVALID_CHIP`, `wifi connect`,
  etc.) → that's the actual hardware test failing. The tester prints the
  on-board exception trace and a `jag decode …` line you can run to
  symbolicate it.

## Where output goes

- Live: stdout when running with `--verbose`.
- Persisted: `build/hw/Testing/Temporary/LastTest.log` (full log of the last
  `ctest` invocation) and `LastTestsFailed.log` (just failures).
- CI logs: `gh run view --repo toitlang/toit --job <id> --log` for the
  `serial` job. Use
  `gh run list --repo toitlang/toit --workflow CI --event schedule` to find
  recent daily runs.

## CI quirks

- The daily runs are scheduled (`event: schedule`) at ~04–05 UTC and almost
  always have *some* failures — the runner hardware is flaky and many tests
  time out under contention. Compare the failing test set across multiple days
  before concluding a regression.
- Setup-fixture timeouts (`setup-board1-esp32`, etc.) cascade: every test in
  that variant reports `Not Run`. Don't count those as test failures.
