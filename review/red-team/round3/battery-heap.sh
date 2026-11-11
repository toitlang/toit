#!/usr/bin/env bash
# Crafted-heap battery (round 3, deliverable 1).
# Edits the program heap of victim.snapshot with heapcraft.toit and runs each
# result untrusted on the normal and the ASan/UBSan build.
#
# The objects and classes are named (`heapcraft find`, below): STR the
# string literal, BA the byte-array literal, FLT the float literal, LAZY a
# LazyInitializer_ (1 field), EXC the Exception_ root (2 fields), NULLO and
# TRUEO the oddballs; CID_* class ids by class name, NCLS the class count
# (the first id out of range); T* back-table indices (for `ref:`). The
# recorded indices of round 3 were STR 33, BA 29, FLT 34, LAZY 0, EXC 122
# with 51 classes.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/battery-env.sh"
CRAFT="$HOSTRUN --project-root tools tools/heapcraft.toit"
BASE="$WORK/victim.snapshot"
battery_compile "$HERE/repro/victim.toit" "$BASE" || exit 2
# The objects and classes by name (`heapcraft find`): their indices change
# with every compilation of the library (the hard-coded ones of round 3 had
# drifted: the method table literal and new failure strings moved the
# objects, new classes the class ids).
read -r STR BA FLT LAZY EXC NULLO TRUEO CID_STRING CID_FLOAT CID_LARGEINT CID_LAZY CID_MAPSTRINGIFY \
    CID_TOMBSTONE CID_LIST CID_LARGEARRAY CID_COW CID_RPCEXC CID_MAP CID_TASK CID_STACK CID_EXC CID_TRUE \
    NCLS TNULL TTRUE TEMPTY TOOR TDIV < <($CRAFT find "$BASE" str:ABCDEFGHIJKLMNOP bytes:0102030405060708 \
    float inst:LazyInitializer_ root:Exception_ inst:Null_ inst:True cls:String_ cls:float cls:LargeInteger_ \
    cls:LazyInitializer_ cls:MapStringify_ cls:Tombstone_ cls:List_ cls:LargeArray_ cls:CowByteArray_ \
    cls:RpcException_ cls:Map cls:Task_ cls:Stack_ cls:Exception_ cls:True classes ref-inst:Null_ \
    ref-inst:True ref-str: ref-str:OUT_OF_RANGE ref-str:DIVISION_BY_ZERO 2>/dev/null | tail -1)
if [ -z "$TDIV" ]; then echo "heapcraft find failed on $BASE" >&2; exit 2; fi
echo "# objects: STR=$STR BA=$BA FLT=$FLT LAZY=$LAZY EXC=$EXC NULL=$NULLO TRUE=$TRUEO; classes: $NCLS" | tee /dev/stderr >/dev/null
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
run_heap base-noop content $STR 4142434445464748494a4b4c4d4e4f50

## FAMILY H5 -- string / byte-array content fed to primitives + encoder
run_heap str-embedded-nul      content $STR 410042434445464748494a4b4c4d4e4f
run_heap str-high-bytes        content $STR fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0
run_heap str-all-ff            content $STR ffffffffffffffffffffffffffffffff
run_heap str-all-zero          content $STR 00000000000000000000000000000000
run_heap str-invalid-utf8-lead content $STR c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0
run_heap str-utf8-truncated    content $STR 41f09f9880f0f0f04142434445464748
run_heap ba-content-ff         content $BA ffffffffffffffff
run_heap ba-content-mixed      content $BA 00ff00ff00ff00ff

## FAMILY H3 -- header bit corruption on consumed literals
run_heap str-finalizer-bit     header $STR raw:$((CID_STRING << 5 | 17))       # cid17<<5 | tag1 | fin-bit(16)=544+16+1
run_heap str-class-edge-max    header $STR class:1023
run_heap str-class-0           header $STR class:0
run_heap str-class-oob         header $STR class:$NCLS
run_heap str-class-50          header $STR class:$((NCLS - 1))
run_heap ba-class-oob          header $BA class:$NCLS
run_heap ba-class-0            header $BA class:0
run_heap float-class-oob       header $FLT class:60
run_heap float-class-largeint  header $FLT class:$CID_LARGEINT       # claim float is LargeInteger_ (tag mismatch?)
run_heap float-finalizer       header $FLT raw:$((CID_FLOAT << 5 | 17))        # cid27<<5(864)|tag4|fin(16)=864+16+4? -> 884

## FAMILY H4 -- optlen / fieldcount desync (loader checks)
run_heap lazy-optlen-2         optlen $LAZY 2
run_heap lazy-optlen-0         optlen $LAZY 0
run_heap lazy-fieldcount-5     fieldcount $LAZY 5
run_heap lazy-fieldcount-0     fieldcount $LAZY 0
run_heap exc-optlen-5          optlen $EXC 5
run_heap exc-fieldcount-0      fieldcount $EXC 0
run_heap exc-fieldcount-9      fieldcount $EXC 9
run_heap str-optlen-huge       optlen $STR 100000
run_heap ba-optlen-big         optlen $BA 2000

## FAMILY H2/H8 -- class-id confusion among same-size instance classes
run_heap lazy-as-mapstringify  header $LAZY class:$CID_MAPSTRINGIFY
run_heap lazy-as-tombstone     header $LAZY class:$CID_TOMBSTONE
run_heap lazy-as-list          header $LAZY class:$CID_LIST      # size mismatch (2 vs 3) -> loader?
run_heap exc-as-list           header $EXC class:$CID_LIST
run_heap exc-as-largearray     header $EXC class:$CID_LARGEARRAY
run_heap exc-as-cowbytearray   header $EXC class:$CID_COW
run_heap exc-as-rpcexception   header $EXC class:$CID_RPCEXC
run_heap exc-as-map            header $EXC class:$CID_MAP     # size mismatch (2 vs 4)
run_heap exc-as-task           header $EXC class:$CID_TASK     # tag mismatch (INSTANCE vs TASK)
run_heap exc-as-stack          header $EXC class:$CID_STACK     # tag mismatch
run_heap str-as-instance       header $STR class:$CID_EXC      # tag mismatch (STRING vs INSTANCE)
run_heap ba-as-list            header $BA class:$CID_LIST       # tag mismatch (BYTE_ARRAY vs INSTANCE)

## FAMILY H1 -- instance field kind confusion
run_heap lazy-field0-smi-huge  field $LAZY 0 smi:1073741823
run_heap lazy-field0-smi-neg   field $LAZY 0 smi:-1
run_heap lazy-field0-ref-str   field $LAZY 0 ref:$TEMPTY
run_heap lazy-field0-ref-odd   field $LAZY 0 ref:$TNULL
run_heap exc-field0-smi        field $EXC 0 smi:12345
run_heap exc-field0-ref-odd    field $EXC 0 ref:$TNULL
run_heap exc-field0-ref-exc    field $EXC 0 ref:$TTRUE
run_heap exc-field1-smi        field $EXC 1 smi:999999
run_heap exc-field1-ref-str    field $EXC 1 ref:$TOOR
run_heap exc-both-wrong        field $EXC 0 smi:1 field $EXC 1 smi:2

## FAMILY H6 -- shared / wrong-kind graphs for the encoder (exception root)
run_heap exc-field0-ref-self-msg field $EXC 0 ref:$TEMPTY     # message -> empty string (kind ok, shared)
run_heap exc-share-oddballs    field $EXC 0 ref:$TNULL field $EXC 1 ref:$TNULL
run_heap exc-field0-ref-str-oob field $EXC 0 ref:$TDIV     # DIVISION_BY_ZERO string as message

## FAMILY H2 -- oddball class-id corruption (null/true/false confusion)
run_heap null-as-true          header $NULLO class:$CID_TRUE       # null oddball -> true's class
run_heap null-class-oob        header $NULLO class:60
run_heap null-as-instance      header $NULLO class:$CID_LAZY       # oddball tag vs instance tag -> loader
run_heap true-class-0          header $TRUEO class:0

## FAMILY H4b -- raw header extremes
run_heap str-raw-header-0      header $STR raw:0
run_heap str-raw-header-huge   header $STR raw:16777215
run_heap exc-raw-header-huge   header $EXC raw:16777215
run_heap lazy-raw-header-neg-tag header $LAZY raw:1       # tag1(string) on an instance -> loader

battery_finish heap
