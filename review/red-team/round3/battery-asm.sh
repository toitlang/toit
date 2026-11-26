#!/usr/bin/env bash
# Assembled-method battery (round 3, deliverable 2).
# Replaces main's body (arity 0, no locals) in num.snapshot with crafted
# instruction sequences, runs each untrusted on the normal + ASan build, and
# records the verifier/loader verdict.  print() method id in num.snapshot = 706.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/battery-env.sh"
ASM="$HOSTRUN --project-root tools tools/asm.toit"
BASE="$WORK/num.snapshot"
battery_compile "$HERE/repro/num.toit" "$BASE" || exit 2
OUT="$WORK/asm"
RES="${RES:-$WORK/asm-results.txt}"
EXPECTED="$HERE/repro/asm-results.txt"
mkdir -p "$OUT"; : > "$RES"
FILTER='primitive\.h\|always evaluates'

reason () { echo "$1" | grep -oiE "untrusted program rejected: [^;]*|VERIFICATION_FAILED|INVALID_SNAPSHOT|AddressSanitizer|runtime error:|SUMMARY: (Address|Undefined)|FATAL|assertion|\bstuck\b|Segmentation|SIGSEGV|STACK_OVERFLOW|Out of memory" | head -1; }

run_asm () {
  local name="$1"; local asm="$2"; local want="${3:-}"
  local snap="$OUT/$name.snapshot"
  if ! $ASM patch "$BASE" "$snap" main "$asm" >/dev/null 2>"$OUT/$name.err"; then
    echo "[$name] ASM-ERROR: $(grep -v 'always evaluates' "$OUT/$name.err" | head -1)" | tee -a "$RES"; return
  fi
  local ho ao hx ax hr ar
  ho=$("$HOSTRUN" --untrusted "$snap" 2>&1 | grep -v 'primitive.h'); hx=${PIPESTATUS[0]}
  ao=$(ASAN_OPTIONS=detect_leaks=false:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 "$ASANRUN" --untrusted "$snap" 2>&1 | grep -v 'primitive.h'); ax=${PIPESTATUS[0]}
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

echo "# Assembled-method battery $(date)" | tee -a "$RES"
# --- baseline valid ---
run_asm good-retnull     'RETURN_NULL'
run_asm good-print55     'LOAD_SMI_U8 55; INVOKE_STATIC @print; RETURN_NULL'
run_asm good-return-val  'LOAD_SMI_0; RETURN'
# --- HALT / trusted-only / out-of-range opcodes ---
run_asm halt-0           'HALT 0'
run_asm halt-deepsleep   'HALT 2'
run_asm halt-reset       'HALT 3'
run_asm opcode-101       'RAW 65'
run_asm opcode-200       'RAW c8'
run_asm opcode-255       'RAW ff'
run_asm opcode-101-ctx   'LOAD_SMI_0; RAW 65; RETURN'
# --- stack underflow / height ---
run_asm pop1-underflow   'POP_1; RETURN_NULL'
run_asm pop-n-underflow  'POP 5; RETURN_NULL'
run_asm add-underflow    'INVOKE_ADD; RETURN_NULL'
run_asm add-one-operand  'LOAD_SMI_0; INVOKE_ADD; RETURN_NULL'
run_asm return-highstack 'LOAD_SMI_0; LOAD_SMI_1; RETURN'
run_asm retnull-highstk  'LOAD_SMI_0; RETURN_NULL'
run_asm loadlocal5-oob   'LOAD_LOCAL_5; RETURN'
run_asm storelocal-high  'LOAD_SMI_0; STORE_LOCAL 64; RETURN_NULL'
run_asm loadlocal-high   'RAW 0040; 5c'
# --- fall off / truncation / mid-instruction ---
run_asm fall-off-end     'LOAD_SMI_0'
run_asm empty-body       'RAW'
run_asm trunc-invoke     'RAW 35'
run_asm trunc-smi        'RAW 1a'
run_asm trunc-primitive  'RAW 59ff'
run_asm branch-into-mid  'RAW 510300 1a0a 5c'
run_asm branch-oob-fwd   'RAW 517f00 5c'
run_asm branch-neg       'LOAD_SMI_0; BRANCH_IF_FALSE Lx; Lx:; RETURN_NULL'
# --- primitives ---
run_asm prim-module-oob  'PRIMITIVE 255 65535; RETURN_NULL'
run_asm prim-idx-oob     'PRIMITIVE 0 65535; RETURN_NULL'
# write_on_stdout (core 0, arity 2, denied for untrusted) from main (arity
# 0): accepted since 2026-11-26 (T2: a denied primitive is completed by the
# core with PERMISSION_DENIED, nothing runs; before, the arity check against
# the full table rejected it); main prints the failure value.
run_asm prim-denied      'PRIMITIVE 0 0; INVOKE_STATIC @print; RETURN_NULL' 'PERMISSION_DENIED'
# --- control-flow merge: height mismatch ---
run_asm merge-height     'LOAD_SMI_0; BRANCH_IF_FALSE Le; LOAD_SMI_1; LOAD_SMI_1; Le:; RETURN_NULL'
run_asm merge-height2    'LOAD_SMI_0; BRANCH_IF_FALSE Le; LOAD_SMI_1; Le:; INVOKE_ADD; RETURN_NULL'
run_asm loop-grow-stack  'Lt:; LOAD_SMI_0; BRANCH_BACK Lt'
run_asm loop-grow-stack2 'LOAD_SMI_0; Lt:; LOAD_SMI_1; INVOKE_ADD; LOAD_SMI_1; BRANCH_BACK Lt'
# --- merge kind confusion: block-ref vs value in same slot, then use ---
run_asm merge-blockref   'LOAD_SMI_0; BRANCH_IF_FALSE Le; LOAD_BLOCK 706; Le:; INVOKE_BLOCK 0; RETURN_NULL'
run_asm merge-methodid   'LOAD_SMI_0; BRANCH_IF_FALSE Le; LOAD_METHOD 706; Le:; INVOKE_LAMBDA_TAIL'
run_asm merge-val-initzr 'LOAD_SMI_0; BRANCH_IF_FALSE Le; LOAD_SMI_1; Le:; INVOKE_INITIALIZER_TAIL'
# --- blocks ---
run_asm loadblock-oob    'LOAD_BLOCK 65000; INVOKE_BLOCK 0; RETURN_NULL'
run_asm loadblock-main   'LOAD_BLOCK 706; INVOKE_BLOCK 0; RETURN_NULL'
run_asm invokeblock-val  'LOAD_SMI_0; INVOKE_BLOCK 0; RETURN_NULL'
run_asm invokeblock-arity 'LOAD_BLOCK 706; LOAD_SMI_0; INVOKE_BLOCK 2; RETURN_NULL'
run_asm loadouterblock   'LOAD_OUTER_BLOCK 0; RETURN_NULL'
# --- non-local return / branch ---
run_asm nonlocal-return  'NON_LOCAL_RETURN'
run_asm nonlocal-return2 'LOAD_SMI_0; NON_LOCAL_RETURN'
run_asm nonlocal-branch  'NON_LOCAL_BRANCH 0 0'
run_asm nonlocal-branch2 'NON_LOCAL_BRANCH 5 1000000'
# --- TRY / UNWIND ---
run_asm unwind-notry     'UNWIND'
run_asm unwind-notry2    'LOAD_SMI_0; LOAD_SMI_0; UNWIND'
run_asm try-alone        'TRY'
run_asm try-ret          'TRY; RETURN_NULL'
run_asm try-unwind       'TRY; UNWIND'
run_asm try-unwind-vals  'LOAD_SMI_0; TRY; LOAD_SMI_0; UNWIND'
# --- tail calls ---
run_asm static-tail-ok   'INVOKE_STATIC_TAIL 706'
run_asm static-tail-oob  'INVOKE_STATIC_TAIL 65000'
run_asm lambda-tail-val  'LOAD_SMI_0; INVOKE_LAMBDA_TAIL'
run_asm lambda-tail-empty 'INVOKE_LAMBDA_TAIL'
run_asm init-tail-val    'LOAD_SMI_0; INVOKE_INITIALIZER_TAIL'
run_asm init-tail-oob    'LOAD_SMI_U16 65000; INVOKE_INITIALIZER_TAIL'
# --- throw / field on wrong receiver ---
run_asm throw-empty      'THROW'
run_asm throw-smi        'LOAD_SMI_0; THROW'
run_asm storefieldthis   'LOAD_SMI_0; STORE_FIELD_THIS 0; RETURN_NULL'
run_asm loadfieldthis    'LOAD_FIELD_THIS 0; RETURN_NULL'
run_asm loadfieldthis-hi 'LOAD_FIELD_THIS 200; RETURN_NULL'
# --- global / literal out of range ---
run_asm loadglobal-oob   'LOAD_GLOBAL_VAR 250; RETURN_NULL'
run_asm loadlit-oob      'LOAD_LITERAL 250; INVOKE_STATIC @print; RETURN_NULL'
run_asm loadlit-wide-oob 'LOAD_LITERAL_WIDE 65000; RETURN_NULL'
run_asm allocate-oob     'ALLOCATE 250; RETURN_NULL'
run_asm invokevirt-oob   'LOAD_SMI_0; INVOKE_VIRTUAL 0 65000; RETURN_NULL'
battery_finish asm
