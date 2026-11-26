#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Red-team round 5, line T: the try/finally of format 3, step 3
# (verified/spec/format/23-format3-try.md). TRY calls its try block as a
# flagged block call; a pending unwinding lives in the finally code's four
# slots [value, token A, token B, reason], the tokens plain smis on the
# object stack. The attacks replace the body of `victim` (cases t-*:
# `victim-throw`, whose try block throws) in repro/tryfin.toit (compiled
# untrusted) with assembled code that forges,
# copies, overwrites, re-pushes or misplaces token words, jumps into and out
# of finally code, and leaves it without its tokens.
#
# Each case runs on the normal and the ASan/UBSan build:
#   --untrusted: the verdict must be the expected one: `reject` (the
#     install-time verifier: "untrusted program rejected") or the exact
#     output of an accepted, well-typed program;
#   trusted on the checked loop (no flag, TOIT_TRUSTED_CHECKED_LOOP=1: no
#     verification, the core checks every step): any outcome but a crash,
#     a sanitizer report, an assertion or a hang (a forged token is stuck
#     in the spec: the checked loop must stop it). A trusted program runs
#     on the verified loop by default (we trust the compiler for
#     first-party code), where an ill-typed one is outside the claim.
# The verdicts are written to $RES; the battery exits non-zero on an
# unexpected verdict or a crash. repro/T-results.txt is a recorded run.
#   %victim, %victim-throw: the method-table index of the method's try
#   block (asm.toit). The block is bound to its method and slot: any other
#   use is rejected (try-foreign-block, nested-reuse).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../round4/battery-env.sh"
if [ ! -x "$ASANRUN" ]; then echo "SKIP line T: no ASan build at $ASANRUN"; exit 0; fi
ASM="$HOSTRUN --project-root tools tools/asm.toit"
BASE="$WORK/tryfin.snapshot"
TOIT_BYTECODE_FORMAT=2 "$(dirname "$HOSTRUN")/toit.compile" --untrusted -w "$BASE" "$HERE/repro/tryfin.toit" || exit 2
OUT="$WORK/asmT"
RES="${RES:-$WORK/T-results.txt}"
mkdir -p "$OUT"; : > "$RES"
FILT='primitive\.h\|gc_metadata\|always evaluates'
ASAN_ENV="ASAN_OPTIONS=detect_leaks=false:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=0"
CRASH='AddressSanitizer|runtime error:|SUMMARY: (Address|Undefined)|assertion|FATAL|SIGSEGV|Segmentation'
STATUS=0

# The verdict of a run: rejected (with the verifier's rule, without the
# method and bci, which change with the library), or what it printed.
verdict () {
  local out="$1"
  local rule
  rule=$(echo "$out" | grep -oE "untrusted program rejected: .*" | head -1 | sed -E 's/method [0-9]+ at bci [0-9]+ \(\+[0-9]+\): //')
  if [ -n "$rule" ]; then echo "reject: $rule"; return; fi
  echo "$out" | grep -qE "VERIFICATION_FAILED" && { echo "reject: VERIFICATION_FAILED"; return; }
  echo "ran: $(echo "$out" | tr '\n' ' ' | sed 's/ *$//' | cut -c1-120)"
}

# case NAME EXPECT ASM: EXPECT is `reject`, `out:TEXT` (the untrusted
# run's output, lines joined by spaces) or `start:TEXT` (its beginning).
case_ () {
  local name="$1" expect="$2" asm="$3"
  local snap="$OUT/$name.snapshot" method=victim arg=""
  if [[ "$name" == t-* ]]; then method=victim-throw; arg=t; fi
  if ! $ASM patch "$BASE" "$snap" $method "$asm" >/dev/null 2>"$OUT/$name.err"; then
    echo "[$name] ASM-ERROR: $(grep -v 'always evaluates' "$OUT/$name.err" | head -1)  <<< TOOL" | tee -a "$RES"
    STATUS=1; return
  fi
  local hu au ht at hx ax tx atx
  hu=$("$HOSTRUN" --untrusted "$snap" $arg 2>&1 | grep -v "$FILT"); hx=${PIPESTATUS[0]}
  au=$(env $ASAN_ENV "$ASANRUN" --untrusted "$snap" $arg 2>&1 | grep -v "$FILT"); ax=${PIPESTATUS[0]}
  ht=$(timeout 60 env TOIT_TRUSTED_CHECKED_LOOP=1 "$HOSTRUN" "$snap" $arg 2>&1 | grep -v "$FILT"); tx=${PIPESTATUS[0]}
  at=$(timeout 120 env TOIT_TRUSTED_CHECKED_LOOP=1 $ASAN_ENV "$ASANRUN" "$snap" $arg 2>&1 | grep -v "$FILT"); atx=${PIPESTATUS[0]}
  local vu va vt flag=""
  vu=$(verdict "$hu"); va=$(verdict "$au"); vt=$(verdict "$ht")
  if echo "$au$at" | grep -qiE "$CRASH" || echo "$hu$ht" | grep -qiE "$CRASH"; then flag="$flag  <<< SANITIZER/CRASH"; fi
  [ "$tx" = 124 ] || [ "$atx" = 124 ] && flag="$flag  <<< TIMEOUT"
  [ "$vu" != "$va" ] && flag="$flag  <<< NORMAL/ASAN DIFFER ($va)"
  case "$expect" in
    reject) [[ "$vu" == reject:* ]] || flag="$flag  <<< UNEXPECTED (want reject)" ;;
    out:*) [ "$vu" = "ran: ${expect#out:}" ] || flag="$flag  <<< UNEXPECTED (want ${expect#out:})" ;;
    start:*) [[ "$vu" == "ran: ${expect#start:}"* ]] || flag="$flag  <<< UNEXPECTED (want ${expect#start:}...)" ;;
  esac
  [ -n "$flag" ] && STATUS=1
  printf '[%s] x{%s/%s/%s/%s} untrusted: %s; trusted: %s%s\n' "$name" "$hx" "$ax" "$tx" "$atx" "$vu" "$vt" "$flag" | tee -a "$RES"
}

echo "# Line-T try/finally battery $(date)" | tee -a "$RES"
# The compiler's shape: TRY, UNWIND (normal token: next instruction).
case_ good-try        'out:4'      'LOAD_METHOD %victim; TRY; UNWIND; POP 1; RETURN_NULL'
# The finally code reads the reason (-1: normal) and the value (null).
case_ good-reason     'out:4 -1 null' 'LOAD_METHOD %victim; TRY; LOAD_LOCAL_0; INVOKE_STATIC @sink; POP_1; LOAD_LOCAL_3; INVOKE_STATIC @sink; POP_1; UNWIND; POP 1; RETURN_NULL'
# victim-throw's try block throws "x": UNWIND resumes the exception (main
# catches it and prints it); the reason is -2.
case_ t-good          'out:x'   'LOAD_METHOD %victim-throw; TRY; UNWIND; POP 1; RETURN_NULL'
case_ t-reason        'out:-2 x' 'LOAD_METHOD %victim-throw; TRY; LOAD_LOCAL_0; INVOKE_STATIC @sink; POP_1; UNWIND; POP 1; RETURN_NULL'
# Finally code that throws itself: the pending exception is dropped.
case_ t-throw-in-finally 'out:9' 'LOAD_METHOD %victim-throw; TRY; LOAD_SMI_U8 9; INVOKE_STATIC @throw; RETURN_NULL'

# --- Forged tokens: smis or other values where TRY's tokens belong. ---
case_ forge-normal    reject 'LOAD_NULL; LOAD_SMI_0; LOAD_SMI_0; LOAD_SMI_0; UNWIND; RETURN_NULL'
case_ forge-throw     reject 'LOAD_NULL; LOAD_SMI_0; LOAD_SMI_1; LOAD_SMI_0; UNWIND; RETURN_NULL'
case_ forge-return    reject 'LOAD_NULL; LOAD_SMI_0; LOAD_SMI_U8 2; LOAD_SMI_0; UNWIND; RETURN_NULL'
# A branch to bci 0 of the bytecodes at height 0 of frame 0 (B = bci*4+3).
case_ forge-branch    reject 'LOAD_NULL; LOAD_SMI_0; LOAD_SMI_U8 3; LOAD_SMI_0; UNWIND; RETURN_NULL'
case_ forge-null      reject 'LOAD_NULL; LOAD_NULL; LOAD_NULL; LOAD_NULL; UNWIND; RETURN_NULL'
case_ forge-method    reject 'LOAD_NULL; LOAD_METHOD %victim; LOAD_METHOD %victim; LOAD_SMI_0; UNWIND; RETURN_NULL'
# Token B replaced by a forged smi (normal), token A kept.
case_ forge-b         reject 'LOAD_METHOD %victim; TRY; POP 2; LOAD_SMI_0; LOAD_SMI_0; UNWIND; POP 1; RETURN_NULL'
# Both tokens replaced: the four slots popped and four smis pushed.
case_ forge-both      reject 'LOAD_METHOD %victim; TRY; POP 4; LOAD_NULL; LOAD_SMI_0; LOAD_SMI_0; LOAD_SMI_0; UNWIND; POP 1; RETURN_NULL'
# Tokens overwritten in place.
case_ store-a         reject 'LOAD_METHOD %victim; TRY; LOAD_SMI_0; STORE_LOCAL 3; POP_1; UNWIND; POP 1; RETURN_NULL'
case_ store-b         reject 'LOAD_METHOD %victim; TRY; LOAD_SMI_1; STORE_LOCAL_POP 2; UNWIND; POP 1; RETURN_NULL'
case_ store-reason    'out:4' 'LOAD_METHOD %victim; TRY; LOAD_SMI_0; STORE_LOCAL_POP 1; UNWIND; POP 1; RETURN_NULL'

# --- Copies of tokens (duplicated, stale). ---
case_ dup-b           reject 'LOAD_METHOD %victim; TRY; LOAD_LOCAL_1; POP_1; UNWIND; POP 1; RETURN_NULL'
case_ dup-a           reject 'LOAD_METHOD %victim; TRY; LOAD_LOCAL_2; POP_1; UNWIND; POP 1; RETURN_NULL'
case_ dup-pop-load    reject 'LOAD_METHOD %victim; TRY; LOAD_NULL; POP_LOAD_LOCAL 2; POP_1; UNWIND; POP 1; RETURN_NULL'
case_ dup-wide        reject 'LOAD_METHOD %victim; TRY; LOAD_LOCAL_WIDE 1; POP_1; UNWIND; POP 1; RETURN_NULL'
# The four slots duplicated above themselves, the copy unwound.
case_ dup-unwind      reject 'LOAD_METHOD %victim; TRY; LOAD_LOCAL_3; LOAD_LOCAL_3; LOAD_LOCAL_3; LOAD_LOCAL_3; UNWIND; UNWIND; POP 1; RETURN_NULL'
# Stale: UNWIND twice (the second on the try block's method id and below).
case_ unwind-twice    reject 'LOAD_METHOD %victim; TRY; UNWIND; UNWIND; RETURN_NULL'
# Tokens of an inner TRY resumed after an outer value was pushed on top.
case_ unwind-off-top  reject 'LOAD_METHOD %victim; TRY; LOAD_SMI_0; UNWIND; POP 2; RETURN_NULL'
# Tokens of an inner finally code mixed with the outer one (nothing can
# move a token: the outer tokens resumed with a smi pair on top).
case_ mix-two-tries   reject 'LOAD_METHOD %victim; TRY; LOAD_METHOD %victim; TRY; POP 3; POP_1; UNWIND; LOAD_SMI_0; LOAD_SMI_0; UNWIND; POP 1; RETURN_NULL'
# A try block is bound to its method and slot: reusing victim's at a
# higher slot (two nested TRYs) is rejected.
case_ nested-reuse    reject 'LOAD_METHOD %victim; TRY; LOAD_METHOD %victim; TRY; UNWIND; POP 1; UNWIND; POP 1; RETURN_NULL'

# --- Tokens as values. ---
case_ token-argument  reject 'LOAD_METHOD %victim; TRY; POP_1; INVOKE_STATIC @sink; RETURN_NULL'
case_ token-return    reject 'LOAD_METHOD %victim; TRY; POP_1; RETURN'
case_ token-throw     reject 'LOAD_METHOD %victim; TRY; POP_1; THROW'
case_ token-identical reject 'LOAD_METHOD %victim; TRY; POP_1; LOAD_NULL; IDENTICAL; POP_1; POP 3; POP 1; RETURN_NULL'
case_ token-branch    reject 'LOAD_METHOD %victim; TRY; POP_1; BRANCH_IF_FALSE Lx; Lx:; POP 3; RETURN_NULL'
case_ token-store-global reject 'LOAD_METHOD %victim; TRY; POP_1; STORE_GLOBAL_VAR 0; POP 4; RETURN_NULL'

# --- Into and out of finally code. ---
# A branch from before TRY into the finally code, at the same height.
case_ jump-in         reject 'LOAD_METHOD %victim; LOAD_NULL; LOAD_SMI_0; LOAD_SMI_0; LOAD_SMI_0; LOAD_SMI_0; BRANCH_IF_FALSE Lf; POP 4; TRY; Lf:; UNWIND; POP 1; RETURN_NULL'
# A branch out of the finally code past UNWIND with the tokens, merging
# with four plain values at the same height.
case_ jump-out-merge  reject 'LOAD_METHOD %victim; TRY; LOAD_SMI_0; BRANCH_IF_FALSE Lx; UNWIND; LOAD_NULL; LOAD_SMI_0; LOAD_SMI_0; LOAD_SMI_0; Lx:; UNWIND; POP 1; RETURN_NULL'
# The same merge, the slots then popped (no UNWIND after the merge).
case_ jump-out-pop    reject 'LOAD_METHOD %victim; TRY; LOAD_SMI_0; BRANCH_IF_FALSE Lx; UNWIND; LOAD_NULL; LOAD_SMI_0; LOAD_SMI_0; LOAD_SMI_0; Lx:; POP 4; POP 1; RETURN_NULL'
# A backward branch from the finally code to before TRY (tokens on the
# stack where the loop head has none).
case_ jump-back       reject 'LOAD_METHOD %victim; LOAD_NULL; LOAD_NULL; LOAD_NULL; LOAD_NULL; Lh:; POP 4; TRY; LOAD_SMI_0; BRANCH_BACK_IF_FALSE Lh; UNWIND; POP 1; RETURN_NULL'
# Leaving the finally code without its tokens: popped (the `break` of
# finally code, which drops the unwinding), then continuing, or returning;
# with victim-throw's try block the exception is dropped (main prints the
# null that catch returns).
case_ leave-pop       'out:4 1' 'LOAD_METHOD %victim; TRY; POP 4; POP 1; LOAD_SMI_1; INVOKE_STATIC @sink; POP_1; RETURN_NULL'
case_ t-leave-pop     'out:null' 'LOAD_METHOD %victim-throw; TRY; POP 4; POP 1; RETURN_NULL'
case_ t-leave-return  'out:null' 'LOAD_METHOD %victim-throw; TRY; RETURN_NULL'
# A pending exception turned into a normal completion: forged, or token B
# overwritten, or resumed twice.
case_ t-forge-normal  reject 'LOAD_METHOD %victim-throw; TRY; POP 4; LOAD_NULL; LOAD_SMI_0; LOAD_SMI_0; LOAD_SMI_0; UNWIND; POP 1; RETURN_NULL'
case_ t-store-b       reject 'LOAD_METHOD %victim-throw; TRY; LOAD_SMI_0; STORE_LOCAL_POP 2; UNWIND; POP 1; RETURN_NULL'
case_ t-dup-unwind    reject 'LOAD_METHOD %victim-throw; TRY; LOAD_LOCAL_3; LOAD_LOCAL_3; LOAD_LOCAL_3; LOAD_LOCAL_3; UNWIND; UNWIND; POP 1; RETURN_NULL'

# --- TRY's operand. ---
case_ try-smi         reject 'LOAD_SMI_0; TRY; UNWIND; POP 1; RETURN_NULL'
case_ try-null        reject 'LOAD_NULL; TRY; UNWIND; POP 1; RETURN_NULL'
# with-return's [0].do block (it reads its enclosing frame through the
# block reference: called as victim's try block, its outer frame differs).
case_ try-foreign-block reject 'LOAD_METHOD %with-return; TRY; UNWIND; POP 1; RETURN_NULL'
# with-throw's try block (arity 1, no outer access) called from victim.
case_ try-other-method reject 'LOAD_METHOD %with-throw; TRY; UNWIND; POP 1; RETURN_NULL'
case_ try-empty-stack reject 'TRY; RETURN_NULL'
# UNWIND with fewer than four slots.
case_ unwind-short    reject 'LOAD_NULL; LOAD_SMI_0; UNWIND; RETURN_NULL'

echo "# done $(date)" | tee -a "$RES"
bad=$(grep -c '<<<' "$RES")
if [ "$STATUS" = 0 ]; then
  echo "battery T: $(grep -c '^\[' "$RES") cases, verdicts as expected, no crash"
else
  echo "battery T: $bad unexpected verdicts or crashes (see $RES)"
fi
exit $STATUS
