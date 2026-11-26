<!-- Copyright (C) 2026 Toit contributors. -->
# Red-team round 5

Attack round against the try/finally of format 3, step 3
(verified/spec/format/23-format3-try.md): TRY calls its try block as a
flagged block call (frame record word `FRAME_HANDLER` = 1), and a pending
unwinding lives in the finally code's four object-stack slots
`[value, token A, token B, reason]`, the two token words plain smis that
encode the unwinding (A: frame and height, B: bci and kind). There are no
finally records any more. The claim under attack: a program cannot forge,
copy, overwrite, resume twice or misplace a token, and cannot reach the
code after UNWIND from the finally code except through UNWIND; the spec
makes every such use stuck, and the install-time verifier rejects it.

See `ATTEMPTS.txt` for the cases and what each one tests. No finding: every
ill-typed case is rejected by the verifier (untrusted), the well-typed ones
print what they should on the normal and the ASan/UBSan build, and nothing
crashes on the checked loop (trusted, `TOIT_TRUSTED_CHECKED_LOOP=1`).

## Battery (wired into `verified/check.sh --tests`, section `redteam5-T`)

Takes `HOSTRUN` (normal build), `ASANRUN` (build/asan) and `WORK` from the
environment and self-checks (exit 1 on an unexpected verdict, a crash, a
sanitizer report, an assertion or a hang).

| Battery | Line | What it does |
|---|---|---|
| `battery-T.sh` | T | replaces the body of `victim` / `victim-throw` (repro/tryfin.toit, compiled untrusted) with assembled code (tools/asm.toit; `%NAME` is the method's try block): forged token pairs (normal, exception, return, branch, null, method ids), token B or both replaced, tokens stored over, copied (LOAD_LOCAL, POP_LOAD_LOCAL, LOAD_LOCAL_WIDE), the four slots duplicated and unwound twice, UNWIND off the top, two finally codes' tokens mixed, tokens as arguments, return values, thrown values, operands of IDENTICAL and branches, stored into a global; branches into the finally code and out of it (forward and backward, height-matched so that only the kinds differ); TRY on a smi, null, an empty stack, another method's block and a reused block; and the well-typed shapes: normal and exceptional completion with the reason and the value read, finally code that throws, and finally code left without its tokens (pop, return), which drops the unwinding as `break`/`return` in Toit finally code does |

The semantic cases in Toit (deep nesting, finally code inside finally
code, non-local return and branch through many finally codes, finally
code that throws, returns, breaks, continues, overflows the stack,
collects and yields while an unwinding is pending, the monitor pattern)
are tests/try-tokens-test.toit (ctest, trusted; and untrusted as
tests/sandbox/cli/try-tokens-*). A program image with a stale tag (TBC1,
TBC2, ...) is refused where programs start: tests/sandbox/stale-tag-test.toit.

## Notes

* A trusted program runs on the verified loop by default (we trust the
  compiler for first-party code, `V2MethodTable::trusted_on_verified_loop`):
  there an ill-typed trusted program is outside the claim (TRY on null
  crashed there, as any ill-typed trusted program may). The battery runs
  the trusted case on the checked loop instead, which must survive any
  program.
* The checked loop cannot tell a token from a smi (as with block
  references): a forged normal token there continues after UNWIND, a
  copied exception token rethrows twice (`forge-b`, `t-forge-normal`,
  `dup-unwind` in repro/T-results.txt). It checks what it resumes, so
  nothing unsafe follows; the verifier rejects all of these for untrusted
  programs.

## Layout
- `battery-T.sh` — the battery.
- `repro/tryfin.toit` — the base program.
- `repro/T-results.txt` — a recorded run (the battery checks verdict
  classes, not this file).
