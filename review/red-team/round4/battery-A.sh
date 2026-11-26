#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
# Red-team round 4, line A: trusted/untrusted confusion via the method
# assembler. Splices the trusted-only unchecked twins (opcodes 104..113), the
# builtins (101..103, allowed but must be checked), trusted-only HALTs and
# out-of-range opcodes into an UNTRUSTED-compiled base, hidden directly, in
# operands, and reached by odd control flow. Each case is run --untrusted on
# the normal and the ASan/UBSan build; the verifier must reject every twin /
# trusted-only / malformed construct with a named rule, and no case may crash
# or trip a sanitizer. Based on round 3's battery-asm.sh.
#  num.snapshot (untrusted): main (arity 0); print is named (@print).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/battery-env.sh"
if [ ! -x "$ASANRUN" ]; then echo "SKIP line A: no ASan build at $ASANRUN"; exit 0; fi
ASM="$HOSTRUN --project-root tools tools/asm.toit"
BASE="$WORK/numA.snapshot"
# Compile the base UNTRUSTED (checked opcodes + certificate); asm drops the
# cert so the host re-infers with the untrusted rules.
"$(dirname "$HOSTRUN")/../../bin/toit" compile --untrusted --snapshot -o "$BASE" "$HERE/repro/num.toit" 2>/dev/null \
  || TOIT_BYTECODE_FORMAT=2 "$(dirname "$HOSTRUN")/toit.compile" --untrusted -w "$BASE" "$HERE/repro/num.toit"
OUT="$WORK/asmA"
RES="${RES:-$WORK/asmA-results.txt}"
EXPECTED="$HERE/repro/asmA-results.txt"
mkdir -p "$OUT"; : > "$RES"
FILT='primitive\.h\|gc_metadata\|always evaluates'

reason () { echo "$1" | grep -oiE "format-2 program rejected: [^;]*|untrusted program rejected: [^;]*|unchecked opcode [0-9]+[^;]*|invalid opcode [0-9]+|VERIFICATION_FAILED|INVALID_SNAPSHOT|AddressSanitizer|runtime error:|SUMMARY: (Address|Undefined)|FATAL|assertion|\bstuck\b|Segmentation|SIGSEGV|STACK_OVERFLOW|Out of memory" | grep -vE 'gc_metadata|primitive.h' | head -1; }

run_asm () {
  local name="$1"; local asm="$2"; local want="${3:-}"
  local snap="$OUT/$name.snapshot"
  if ! $ASM patch "$BASE" "$snap" main "$asm" >/dev/null 2>"$OUT/$name.err"; then
    echo "[$name] ASM-ERROR: $(grep -v 'always evaluates' "$OUT/$name.err" | head -1)" | tee -a "$RES"; return
  fi
  local ho ao hx ax hr ar
  ho=$("$HOSTRUN" --untrusted "$snap" 2>&1 | grep -v "$FILT"); hx=${PIPESTATUS[0]}
  ao=$(ASAN_OPTIONS=detect_leaks=false:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=0 "$ASANRUN" --untrusted "$snap" 2>&1 | grep -v "$FILT"); ax=${PIPESTATUS[0]}
  hr=$(reason "$ho"); ar=$(reason "$ao")
  [ -z "$hr" ] && hr="ACCEPTED->ran: $(echo "$ho" | tr '\n' ' ' | cut -c1-40)"
  local flag=""
  echo "$ao" | grep -qiE "AddressSanitizer|runtime error:|SUMMARY: (Address|Undef)|assertion|FATAL|SIGSEGV|Segmentation" && flag="  <<< SANITIZER/CRASH"
  # A case with an expected output must be accepted and print it, on both
  # builds (a check of the run, not only of the recorded verdict).
  if [ -n "$want" ]; then
    if [ -n "$(reason "$ho")" ] || [ "$(echo "$ho" | tr '\n' ' ')" != "$want " ] \
        || [ "$(echo "$ao" | tr '\n' ' ')" != "$want " ]; then
      flag="$flag  <<< UNEXPECTED (want the output: $want)"
    fi
  fi
  printf '[%s] x{%s/%s} %s %s\n' "$name" "$hx" "$ax" "$hr" "$flag" | tee -a "$RES"
}

echo "# Line-A assembled-method battery $(date)" | tee -a "$RES"
# --- baseline valid untrusted body ---
run_asm good-retnull     'RETURN_NULL'
run_asm good-print       'LOAD_SMI_U8 55; INVOKE_STATIC @print; RETURN_NULL'
# --- the ten unchecked twins, direct (expect "unchecked opcode N") ---
run_asm twin-104-loadf        'LOAD_SMI_0; RAW 68; RETURN_NULL'
run_asm twin-105-loadfwide    'LOAD_SMI_0; RAW 690000; RETURN_NULL'
run_asm twin-106-loadflocal   'LOAD_SMI_0; RAW 6a00; RETURN_NULL'
run_asm twin-107-poploadfloc  'LOAD_SMI_0; RAW 6b00; RETURN_NULL'
run_asm twin-108-storef       'LOAD_SMI_0; LOAD_SMI_0; RAW 6c00; RETURN_NULL'
run_asm twin-109-storefwide   'LOAD_SMI_0; LOAD_SMI_0; RAW 6d0000; RETURN_NULL'
run_asm twin-110-storefpop    'LOAD_SMI_0; LOAD_SMI_0; RAW 6e00; RETURN_NULL'
run_asm twin-111-ivget        'LOAD_SMI_0; RAW 6f0000; RETURN_NULL'
run_asm twin-112-ivset        'LOAD_SMI_0; LOAD_SMI_0; RAW 700000; RETURN_NULL'
run_asm twin-113-storefthis   'LOAD_SMI_0; RAW 7100; RETURN_NULL'
# --- twins in odd positions ---
run_asm twin-after-return     'RETURN_NULL; RAW 68'
run_asm twin-branch-reached   'LOAD_SMI_0; BRANCH_IF_FALSE Lx; RETURN_NULL; Lx:; LOAD_SMI_0; RAW 68; RETURN_NULL'
run_asm twin-first-insn       'RAW 6800; RETURN_NULL'
run_asm twin-as-operand-byte  'RAW 1a68; RETURN_NULL'
run_asm twin-branch-into-twin 'RAW 510400 1a68 5c'
# --- out-of-range opcode 119..255 (114..118: the short branches of format 3) ---
run_asm op-119                'RAW 77'
run_asm op-200                'RAW c8'
run_asm op-255               'RAW ff'
run_asm op-119-ctx           'LOAD_SMI_0; RAW 77; RETURN'
# --- the short branches (format 3, verified/spec/format/22-format3-branches-frames.md) ---
run_asm sbr-good             'LOAD_SMI_1; BRANCH_IF_FALSE_S Lx; LOAD_SMI_U8 55; INVOKE_STATIC @print; POP_1; Lx:; LOAD_SMI_U8 56; INVOKE_STATIC @print; RETURN_NULL'
run_asm sbr-zero             'RAW 7200; RETURN_NULL'
run_asm sbr-cond-zero        'LOAD_SMI_0; RAW 7400; RETURN_NULL'
run_asm sbr-out              'RAW 72ff; RETURN_NULL'
run_asm sbr-into-operand     'RAW 7203; LOAD_SMI_U8 55; RETURN_NULL'
run_asm sbr-past-end         'RETURN_NULL; RAW 72'
run_asm sbr-back-before      'RAW 7605; RETURN_NULL'
run_asm sbr-back-loop        'Lt:; LOAD_SMI_0; BRANCH_BACK_S Lt'
run_asm sbr-merge-height     'LOAD_SMI_0; BRANCH_IF_FALSE_S Le; LOAD_SMI_1; Le:; RETURN_NULL'
# --- trusted-only HALTs (should be rejected for untrusted) ---
run_asm halt-deepsleep       'HALT 2'
run_asm halt-reset           'HALT 3'
run_asm halt-0               'HALT 0'
# --- builtins 101..103 (ALLOWED untrusted; must still be checked) ---
run_asm builtin-101-repeat   'RAW 65000000; RETURN_NULL'
run_asm builtin-102-array    'RAW 66000000; RETURN_NULL'
run_asm builtin-103-hashfind 'RAW 6700000000; RETURN_NULL'
run_asm builtin-101-operands 'LOAD_SMI_0; LOAD_SMI_0; RAW 65ffff00; RETURN_NULL'
run_asm builtin-103-badargs  'LOAD_SMI_0; RAW 67ffffffff; RETURN_NULL'
# --- primitive gating under untrusted (T2, 2026-11-26) ---
# The verifier takes a PRIMITIVE the untrusted policy's table lists:
# allowed with the method's arity, denied (any arity), or in a module the
# policy denies as a whole (any arity); the core runs only allowed ones and
# completes a denied one with PERMISSION_DENIED, calling nothing (the
# failure value is on the stack and main prints it). Until 2026-11-26 these
# were rejected at install (the arity check against the full table): the
# first two cases are the old prim-spawn body, made observable.
#   core 0 = write_on_stdout/2, core 101 = spawn/3, module 2 = tcp.
run_asm prim-spawn           'PRIMITIVE 0 101; INVOKE_STATIC @print; RETURN_NULL' 'PERMISSION_DENIED'
run_asm prim-stdout-arity0   'PRIMITIVE 0 0; INVOKE_STATIC @print; RETURN_NULL' 'PERMISSION_DENIED'
# Indices past the VM's table name no primitive: rejected at install.
run_asm prim-module-oob      'PRIMITIVE 255 65535; RETURN_NULL'
run_asm prim-idx-oob         'PRIMITIVE 0 65535; RETURN_NULL'
run_asm prim-absent-idx-oob  'PRIMITIVE 2 65535; RETURN_NULL'
# --- mixing: a twin preceded by a valid checked field setup ---
run_asm mix-checked-twin     'LOAD_SMI_0; RAW 7100; LOAD_SMI_0; RAW 6800; RETURN_NULL'
run_asm twin-105-highop      'LOAD_SMI_0; RAW 69ffff; RETURN_NULL'
run_asm twin-111-highsel     'LOAD_SMI_0; RAW 6fffff; RETURN_NULL'
# --- an inconsistent method table (format note 21): the body changes size
# but the records of the following methods are not moved (asm
# --stale-table), so they point into other methods' code; the loader must
# refuse the program cleanly, untrusted and trusted (no verification), on
# both builds. The same-size body keeps the table consistent.
run_table () {
  local name="$1"; local asm="$2"
  local snap="$OUT/$name.snapshot"
  if ! $ASM patch --stale-table "$BASE" "$snap" main "$asm" >/dev/null 2>"$OUT/$name.err"; then
    echo "[$name] ASM-ERROR: $(grep -v 'always evaluates' "$OUT/$name.err" | head -1)" | tee -a "$RES"; return
  fi
  local hu au ht at hx ax tx atx
  hu=$("$HOSTRUN" --untrusted "$snap" 2>&1 | grep -v "$FILT"); hx=${PIPESTATUS[0]}
  ht=$("$HOSTRUN" "$snap" 2>&1 | grep -v "$FILT"); tx=${PIPESTATUS[0]}
  au=$(ASAN_OPTIONS=detect_leaks=false:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=0 "$ASANRUN" --untrusted "$snap" 2>&1 | grep -v "$FILT"); ax=${PIPESTATUS[0]}
  at=$(ASAN_OPTIONS=detect_leaks=false:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=0 "$ASANRUN" "$snap" 2>&1 | grep -v "$FILT"); atx=${PIPESTATUS[0]}
  local ur tr
  ur=$(reason "$hu"); [ -z "$ur" ] && ur="ACCEPTED->ran: $(echo "$hu" | tr '\n' ' ' | cut -c1-40)"
  tr=$(reason "$ht"); [ -z "$tr" ] && tr="ran: $(echo "$ht" | tr '\n' ' ' | cut -c1-40)"
  local r="untrusted: $ur; trusted: $tr"
  local flag=""
  echo "$au$at" | grep -qiE "AddressSanitizer|runtime error:|SUMMARY: (Address|Undef)|assertion|FATAL|SIGSEGV|Segmentation" && flag="  <<< SANITIZER/CRASH"
  printf '[%s] x{%s/%s/%s/%s} %s %s\n' "$name" "$hx" "$tx" "$ax" "$atx" "$r" "$flag" | tee -a "$RES"
}
run_table table-stale-shorter  'RETURN_NULL'
run_table table-stale-longer   'LOAD_SMI_0; POP 1; LOAD_SMI_0; POP 1; LOAD_SMI_0; POP 1; RETURN_NULL'
run_table table-stale-by-one   'LOAD_SMI_0; POP 1; LOAD_SMI_0; POP 1; LOAD_SMI_0; RETURN_NULL'
run_table table-same-size      'LOAD_SMI_U8 55; INVOKE_STATIC @print; RETURN_NULL'

# --- T2: denied and absent primitives whose failure the program sees ---
# repro/prims.toit: each call in a method whose body is the PRIMITIVE with
# a failure block returning what it failed with (absent primitives throw:
# main catches). The compiler checks arities, so the wrong-arity methods are
# placeholders the assembler fills (one per snapshot: the assembler finds
# methods by name, and a patched snapshot has no names left). Each checked
# output line is a case and must be exactly the expected one, on both
# builds, and the run must exit 0:
#   prims-*       untrusted, no certificate (the host infers);
#   prims-cert-*  the compiled program untrusted with its shipped
#                 certificate (the host checks a present certificate and
#                 does not infer; the --require-certificate verdicts are
#                 battery-A-cert.sh's prims-* cases);
#   prims-trusted-spawn  the same program trusted: spawn reaches the C++
#                 (which rejects the arguments), so INVALID_ARGUMENT, where
#                 untrusted nothing runs.
# run_prims PREFIX SNAPSHOT FLAGS NAME|LINE|TEXT...
run_prims () {
  local prefix="$1" snap="$2" flags="$3"; shift 3
  local ho ao hx ax
  ho=$("$HOSTRUN" $flags "$snap" 2>&1 | grep -v "$FILT"); hx=${PIPESTATUS[0]}
  ao=$(ASAN_OPTIONS=detect_leaks=false:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=0 "$ASANRUN" $flags "$snap" 2>&1 | grep -v "$FILT"); ax=${PIPESTATUS[0]}
  local crash=""
  echo "$ao" | grep -qiE "AddressSanitizer|runtime error:|SUMMARY: (Address|Undef)|assertion|FATAL|SIGSEGV|Segmentation" && crash="  <<< SANITIZER/CRASH"
  local e name line got agot flag
  for e in "$@"; do
    name="${e%%|*}"; e="${e#*|}"; line="${e%%|*}"; e="${e#*|}"
    got=$(echo "$ho" | sed -n "${line}p"); agot=$(echo "$ao" | sed -n "${line}p")
    flag="$crash"
    if [ "$got" != "$e" ] || [ "$agot" != "$e" ] || [ "$hx" != 0 ] || [ "$ax" != 0 ]; then
      flag="$flag  <<< UNEXPECTED (want: $e)"
    fi
    printf '[%s-%s] x{%s/%s} ran: %s %s\n' "$prefix" "$name" "$hx" "$ax" "$got" "$flag" | tee -a "$RES"
  done
}
PRIMS="$WORK/prims.snapshot"
"$(dirname "$HOSTRUN")/../../bin/toit" compile --untrusted --snapshot -o "$PRIMS" "$HERE/repro/prims.toit" 2>/dev/null \
  || TOIT_BYTECODE_FORMAT=2 "$(dirname "$HOSTRUN")/toit.compile" --untrusted -w "$PRIMS" "$HERE/repro/prims.toit"
# prims_patch NAME METHOD ASM CASE...: PRIMS with METHOD's body replaced
# (the assembler drops the certificate: the host infers), run untrusted.
prims_patch () {
  local name="$1" method="$2" asm="$3"; shift 3
  if $ASM patch "$PRIMS" "$OUT/prims-$name.snapshot" "$method" "$asm" >/dev/null 2>"$OUT/prims-$name.err"; then
    run_prims prims "$OUT/prims-$name.snapshot" --untrusted "$@"
  else
    echo "[prims-$name] ASM-ERROR: $(grep -v 'always evaluates' "$OUT/prims-$name.err" | head -1)" | tee -a "$RES"
  fi
}
# Denied with the right arity, absent with the right arity (tcp-close-2's
# own body, reassembled, so that the program has no certificate).
prims_patch tcp tcp-close-2 'PRIMITIVE 2 1; RETURN' \
  'spawn|1|spawn: failed PERMISSION_DENIED' \
  'stdout|2|stdout: failed PERMISSION_DENIED' \
  'tcp-absent|5|tcp: PRIMITIVE_LOOKUP_FAILED' \
  'done|7|done'
# Denied and absent with a wrong arity.
prims_patch spawn-arity-1 spawn-1 'PRIMITIVE 0 101; RETURN' \
  'spawn-arity-1|3|spawn-arity-1: PERMISSION_DENIED'
prims_patch stdout-arity-0 stdout-0 'PRIMITIVE 0 0; RETURN' \
  'stdout-arity-0|4|stdout-arity-0: PERMISSION_DENIED'
prims_patch tcp-arity-5 tcp-close-5 'PRIMITIVE 2 1; RETURN' \
  'tcp-absent-arity-5|6|tcp-arity-5: PRIMITIVE_LOOKUP_FAILED'
run_prims prims-cert "$PRIMS" --untrusted \
  'spawn|1|spawn: failed PERMISSION_DENIED' \
  'stdout|2|stdout: failed PERMISSION_DENIED' \
  'tcp-absent|5|tcp: PRIMITIVE_LOOKUP_FAILED' \
  'done|7|done'
run_prims prims-trusted "$PRIMS" "" \
  'spawn|1|spawn: failed INVALID_ARGUMENT'
battery_finish asm
