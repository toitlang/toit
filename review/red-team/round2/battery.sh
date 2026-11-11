#!/usr/bin/env bash
# Crafted-bytecode battery against the format-2 verifier/core.
# Base: num.snapshot, main at header bci 222: [arity=00][flags=00][body=06]
#   entry=225 body: 1a 64 | 35 c2 02 | 5c
#   (LOAD_SMI_U8 100 ; INVOKE_STATIC 0x02c2 ; RETURN_NULL)
set -u
WT=/home/flo/work/opentoit-sandbox/.claude/worktrees/agent-a2db25f6a88797df3
cd "$WT"
B=build/host/sdk/lib/toit/bin
CRAFT="$B/toit.run --project-root tools review/red-team/round2/craft.toit"
RUN="$B/toit.run --untrusted"
OUT=review/red-team/round2/repro
mkdir -p "$OUT"
# Build the base snapshot used by all patches (main at header bci 222).
$B/toit.compile -Xbytecode_format=2 -w /tmp/rt2/num.snapshot "$OUT/num.toit"
run_one () {
  local name="$1"; shift
  local snap="$OUT/$name.snapshot"
  $CRAFT patch /tmp/rt2/num.snapshot "$snap" "$@" >/dev/null 2>&1 \
    || { echo "[$name] CRAFT-ERROR (loader rejected at build?)"; }
  local v
  v=$($RUN "$snap" 2>&1 | grep -E "verifier:|rejected|Failed to start|error|sum|^[0-9]+$|Runtime|Abort|Sanitizer" | head -2)
  echo "[$name] $v"
}
echo "# Crafted bytecode battery $(date)"
# A header-level (loader) attacks: patch the method header at 222/223
run_one hdr-bad-flags        223 0f            # invalid flag bits
run_one hdr-arity-255        222 ff            # giant arity on entry method
run_one hdr-kind-block       223 03            # claim main is a BLOCK (kind 3)
run_one hdr-kind-lambda      223 02            # claim main is a LAMBDA (needs aux)
# B opcode-level attacks: patch main body at entry 225..230
run_one op-out-of-range      225 65            # opcode 101 >= OPCODE_COUNT2
run_one op-halt-deepsleep    225 6402          # HALT 2 (deep sleep)
run_one op-halt-reset        225 6403          # HALT 3 (reset)
run_one op-pop-underflow     225 2802          # POP 2 with empty stack
run_one op-trunc-invoke      230 35            # RETURN_NULL(len1) -> INVOKE_STATIC(len3) past end
run_one op-branch-mid        225 500100        # BRANCH into middle of next instr
run_one op-return-midstack   225 5b            # RETURN (op 0x5b=91) with wrong height
run_one op-primitive-oob     225 59ffffff      # PRIMITIVE module 255 idx ... (len4)
run_one op-store-local-high  225 0340          # STORE_LOCAL 0x40 (beyond frame)
run_one op-invoke-virtual-bad 225 3affff       # INVOKE_VIRTUAL huge dispatch offset (len3)
run_one op-load-literal-oob  225 14ff          # LOAD_LITERAL 255 (op20 len2) maybe oob
echo "# done"
