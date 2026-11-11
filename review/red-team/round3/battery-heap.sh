#!/usr/bin/env bash
# Crafted-heap battery (round 3, deliverable 1).
# Edits the program heap of victim.snapshot with heapcraft.toit and runs each
# result untrusted on the normal and the ASan/UBSan build.
#
# victim.snapshot object indices (heapcraft list):
#   #33 STR (String_ cid17)   #29 BA (ByteArray_ cid43)   #34 float (cid27)
#   #0  LazyInitializer_ (cid20,1 field)   #122 Exception_ root (cid36,2 fields)
#   back-table: T0=null T1=true/false-oddball T3="" T4="OUT_OF_RANGE" ...
# class table: 51 classes (cid 0..50). size2: LazyInit(20)/MapStringify(37)/
#   Tombstone(40). size3: Exception(36)/List_(44)/LargeArray(46)/Cow(41)/Rpc(3).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/battery-env.sh"
CRAFT="$HOSTRUN --project-root tools tools/heapcraft.toit"
BASE="$WORK/victim.snapshot"
battery_compile "$HERE/repro/victim.toit" "$BASE" || exit 2
OUT="$WORK/heap"
RES="${RES:-$WORK/heap-results.txt}"
EXPECTED="$HERE/repro/heap-results.txt"
mkdir -p "$OUT"
: > "$RES"
FILTER='primitive\.h'

verdict () {  # $1 text -> short classification
  echo "$1" | grep -oiE "ERROR: AddressSanitizer|runtime error:|SUMMARY: (Address|Undefined)|Segmentation|signal SIGSEGV|FATAL|\bstuck\b|internal error|Abort|instance size does not match|class id out of range|object tag does not match|non-smi object header|variable-sized object|invalid object tag|too many table objects|object length exceeds|back reference to an object|objects nested too deeply|program heap exhausted|verification failed|rejected|INVALID|Failed to start|Out of memory|STACK_OVERFLOW|WRONG_OBJECT_TYPE|OUT_OF_BOUNDS|OUT_OF_RANGE|PERMISSION_DENIED|ILLEGAL_UTF_8|WRONG_BYTES_TYPE" | head -1
}

run_heap () {
  local name="$1"; shift
  local snap="$OUT/$name.snapshot"
  if ! $CRAFT edit "$BASE" "$snap" "$@" >/dev/null 2>"$OUT/$name.crafterr"; then
    echo "[$name] CRAFT-ERROR: $(head -1 "$OUT/$name.crafterr")" | tee -a "$RES"
    return
  fi
  local ho ao hv av hx ax
  ho=$("$HOSTRUN" --untrusted "$snap" 2>&1 | grep -v "$FILTER"); hx=${PIPESTATUS[0]}
  ao=$(ASAN_OPTIONS=detect_leaks=false:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 "$ASANRUN" --untrusted "$snap" 2>&1 | grep -v "$FILTER"); ax=${PIPESTATUS[0]}
  hv=$(verdict "$ho"); av=$(verdict "$ao")
  [ -z "$hv" ] && hv="(ran, exit $hx)"
  [ -z "$av" ] && av="(ran, exit $ax)"
  local flag=""
  echo "$ao" | grep -qiE "AddressSanitizer|runtime error:|SUMMARY: (Address|Undefined)|SEGV|Segmentation" && flag="  <<< SANITIZER"
  echo "$ho$ao" | grep -qiE "FATAL|internal error|\bstuck\b|Segmentation|SIGSEGV" && flag="$flag  <<< CRASH/INTERNAL"
  printf '[%s] host:{%s x%s} asan:{%s x%s}%s\n' "$name" "$hv" "$hx" "$av" "$ax" "$flag" | tee -a "$RES"
}

echo "# Crafted-heap battery $(date)" | tee -a "$RES"
# sanity: unedited (prove pipeline) -- use a no-op content rewrite of STR to itself
run_heap base-noop content 33 4142434445464748494a4b4c4d4e4f50

## FAMILY H5 -- string / byte-array content fed to primitives + encoder
run_heap str-embedded-nul      content 33 410042434445464748494a4b4c4d4e4f
run_heap str-high-bytes        content 33 fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0
run_heap str-all-ff            content 33 ffffffffffffffffffffffffffffffff
run_heap str-all-zero          content 33 00000000000000000000000000000000
run_heap str-invalid-utf8-lead content 33 c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0
run_heap str-utf8-truncated    content 33 41f09f9880f0f0f04142434445464748
run_heap ba-content-ff         content 29 ffffffffffffffff
run_heap ba-content-mixed      content 29 00ff00ff00ff00ff

## FAMILY H3 -- header bit corruption on consumed literals
run_heap str-finalizer-bit     header 33 raw:561       # cid17<<5 | tag1 | fin-bit(16)=544+16+1
run_heap str-class-edge-max    header 33 class:1023
run_heap str-class-0           header 33 class:0
run_heap str-class-oob         header 33 class:51
run_heap str-class-50          header 33 class:50
run_heap ba-class-oob          header 29 class:51
run_heap ba-class-0            header 29 class:0
run_heap float-class-oob       header 34 class:60
run_heap float-class-largeint  header 34 class:28       # claim float is LargeInteger_ (tag mismatch?)
run_heap float-finalizer       header 34 raw:881        # cid27<<5(864)|tag4|fin(16)=864+16+4? -> 884

## FAMILY H4 -- optlen / fieldcount desync (loader checks)
run_heap lazy-optlen-2         optlen 0 2
run_heap lazy-optlen-0         optlen 0 0
run_heap lazy-fieldcount-5     fieldcount 0 5
run_heap lazy-fieldcount-0     fieldcount 0 0
run_heap exc-optlen-5          optlen 122 5
run_heap exc-fieldcount-0      fieldcount 122 0
run_heap exc-fieldcount-9      fieldcount 122 9
run_heap str-optlen-huge       optlen 33 100000
run_heap ba-optlen-big         optlen 29 2000

## FAMILY H2/H8 -- class-id confusion among same-size instance classes
run_heap lazy-as-mapstringify  header 0 class:37
run_heap lazy-as-tombstone     header 0 class:40
run_heap lazy-as-list          header 0 class:44      # size mismatch (2 vs 3) -> loader?
run_heap exc-as-list           header 122 class:44
run_heap exc-as-largearray     header 122 class:46
run_heap exc-as-cowbytearray   header 122 class:41
run_heap exc-as-rpcexception   header 122 class:3
run_heap exc-as-map            header 122 class:38     # size mismatch (2 vs 4)
run_heap exc-as-task           header 122 class:14     # tag mismatch (INSTANCE vs TASK)
run_heap exc-as-stack          header 122 class:26     # tag mismatch
run_heap str-as-instance       header 33 class:36      # tag mismatch (STRING vs INSTANCE)
run_heap ba-as-list            header 29 class:44       # tag mismatch (BYTE_ARRAY vs INSTANCE)

## FAMILY H1 -- instance field kind confusion
run_heap lazy-field0-smi-huge  field 0 0 smi:1073741823
run_heap lazy-field0-smi-neg   field 0 0 smi:-1
run_heap lazy-field0-ref-str   field 0 0 ref:3
run_heap lazy-field0-ref-odd   field 0 0 ref:0
run_heap exc-field0-smi        field 122 0 smi:12345
run_heap exc-field0-ref-odd    field 122 0 ref:0
run_heap exc-field0-ref-exc    field 122 0 ref:1
run_heap exc-field1-smi        field 122 1 smi:999999
run_heap exc-field1-ref-str    field 122 1 ref:4
run_heap exc-both-wrong        field 122 0 smi:1 field 122 1 smi:2

## FAMILY H6 -- shared / wrong-kind graphs for the encoder (exception root)
run_heap exc-field0-ref-self-msg field 122 0 ref:3     # message -> empty string (kind ok, shared)
run_heap exc-share-oddballs    field 122 0 ref:0 field 122 1 ref:0
run_heap exc-field0-ref-str-oob field 122 0 ref:12     # DIVISION_BY_ZERO string as message

## FAMILY H2 -- oddball class-id corruption (null/true/false confusion)
run_heap null-as-true          header 4 class:24       # null oddball -> true's class
run_heap null-class-oob        header 4 class:60
run_heap null-as-instance      header 4 class:20       # oddball tag vs instance tag -> loader
run_heap true-class-0          header 16 class:0

## FAMILY H4b -- raw header extremes
run_heap str-raw-header-0      header 33 raw:0
run_heap str-raw-header-huge   header 33 raw:16777215
run_heap exc-raw-header-huge   header 122 raw:16777215
run_heap lazy-raw-header-neg-tag header 0 raw:1       # tag1(string) on an instance -> loader

battery_finish heap
