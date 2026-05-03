---
name: debug-lsp-repro
description: Use this when debugging compiler crashes captured as LSP "repro" tar archives (e.g. attached to GitHub issues). Explains how to extract a repro, replay it against `toit.compile`, get a symbolized backtrace under gdb, and reduce the crash to a minimal source snippet that fits in `tests/negative/`.
---

# Debugging LSP repro tar archives

The LSP server (and the standalone `tools/lsp/server/repro.toit` tool) can
capture a "repro" — a tar file containing every source file the compiler
served plus the exact stdin that drove it. These archives end up on GitHub
issues whenever the LSP segfaults or asserts. This skill is the runbook for
turning one of those archives into a fix.

## Tar archive layout

Each repro tar contains the original served files at their absolute paths
plus these special metadata members:

| Member                       | Purpose                                            |
|------------------------------|----------------------------------------------------|
| `/<info>`                    | Crash reason (`Segmentation fault`, `Killed`, …)  |
| `/<compiler-input>`          | Stdin payload that drove the compiler             |
| `/<compiler-flags>`          | Newline-separated CLI flags (usually `--lsp …`)   |
| `/<cwd>`                     | Original working directory                        |
| `/<sdk-path>`                | SDK root used                                     |
| `/<package-cache-paths>`     | Newline-separated package cache paths             |
| `/<meta>`                    | JSON: `{files: …, directories: …}` metadata       |

`tar xOf <archive> '/<info>'` is the fastest way to triage: ignore archives
whose info is just `Killed after timeout` (load issue, not a real crash);
keep the ones with `Segmentation fault`, `assertion failure`, etc.

## Reproducing a crash

The compiler talks to the file server over TCP. Two steps:

1. Run `toit tools/lsp/server/repro.toit serve --port=0 <archive>` in the
   background. It prints `Server started at <port>` and keeps serving.
2. Drive `toit.compile -Xno_fork --lsp` with stdin = `<port>\n` followed
   by the contents of `/<compiler-input>`.

For a quick session, this script (drop it next to your repros) does both
and optionally runs the compiler under `gdb --batch` for a symbolized
backtrace:

```bash
#!/usr/bin/env bash
# usage: run_repro.sh <archive.tar> [gdb]
set -u
ARCHIVE=${1:?need archive}; GDB=${2:-}
REPO=/path/to/toit
TOIT=$REPO/build/host/sdk/bin/toit
COMPILE=$REPO/build/host/sdk/lib/toit/bin/toit.compile

WORK=$(mktemp -d); LOG=$WORK/server.log
tar xOf "$ARCHIVE" '/<compiler-input>' > "$WORK/in" 2>/dev/null
"$TOIT" run "$REPO/tools/lsp/server/repro.toit" -- serve --port=0 "$ARCHIVE" \
    > "$LOG" 2>&1 &
SERVER=$!
for _ in $(seq 50); do
  grep -q 'Server started at' "$LOG" && break; sleep 0.2
done
PORT=$(awk '/Server started at/{print $4; exit}' "$LOG")
{ echo "$PORT"; cat "$WORK/in"; } > "$WORK/stdin"
if [[ "$GDB" == gdb ]]; then
  gdb --batch -ex 'set pagination off' -ex 'handle SIGPIPE nostop noprint pass' \
      -ex run -ex bt -ex 'bt full' -ex 'thread apply all bt' \
      --args "$COMPILE" -Xno_fork --lsp < "$WORK/stdin"
else
  "$COMPILE" -Xno_fork --lsp < "$WORK/stdin"
fi
kill $SERVER 2>/dev/null; wait 2>/dev/null
```

Build the SDK with debug info first (`-O0 -g`) so backtraces are useful;
otherwise gdb shows raw addresses only. See `make debug`. You might need to
delete `build/host` first.

## From repro to minimal test

Once you have a stack trace and the assertion file:line, look at the
served source the compiler was analyzing — the path is the last line of
`/<compiler-input>` (often an `inmemory://…` document):

```
tar xOf <archive> '<served-path>'
```

Then reduce. The repro often involves parser error-recovery, so the crash
may depend on subtle textual conditions (leading indentation, missing
preceding declarations). Two tactics that help reduce:

- Try the same snippet through the *non-LSP* path:
  `toit analyze --analyze /tmp/min.toit`. If it crashes there too, the bug
  isn't LSP-specific and the test belongs in `tests/negative/`.
- If you need LSP-only behaviour to crash, write the test in
  `tests/lsp/` and drive it with `LspClient` (see
  `tests/lsp/repro-compiler-test-slow.toit` for the pattern).

## Writing a negative test

`tests/negative/<name>-test.toit` files are run via `toit.run`; the
compiler error output is compared to `tests/negative/gold/<name>-test.gold`.
The runner expects a non-zero exit code, so the test must trigger at least
one compile error.

To generate / refresh gold files after changing a test:

```
make update-gold
```

Then run the single test:

```
(cd build/host && ctest -R '<name>' --output-on-failure)
```
