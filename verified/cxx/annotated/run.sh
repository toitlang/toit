#!/usr/bin/env bash
# Copyright (C) 2026 Toit contributors.
#
# The VeriFast matrix of the residual C++ (verified/cxx/annotated/README.md):
#   1. the renderings are what the current sources and sidecars give
#      (render.sh --check: drift fails here);
#   2. every constant they use has the value of the C++ headers, 64- and
#      32-bit (constants-check.sh);
#   3. VeriFast on every rendering, LP64 and ILP32, with its expected
#      verdict;
#   4. the reverted-bug self-tests (mutant.sh): each must fail where the
#      bug is;
#   5. the Rust raw-memory layer (VeriFast's Rust front end).
#
# Usage: run.sh [--quick] [FILTER]
#   FILTER: only the entries whose name contains it. --quick: no mutants.
# Exit status: 0 when every entry has its expected verdict. Exit status 3
# (and a SKIP line) when VeriFast is not installed (install-tools.sh).

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
acxx_lock
QUICK=0
if [ "${1:-}" = --quick ]; then QUICK=1; shift; fi
filter="${1:-}"
cd "$ANNOTATED_DIR"

if [ ! -x "$VERIFAST" ]; then
  echo "SKIP: VeriFast $VERIFAST_VERSION is not installed at $VERIFAST_DIR (verified/cxx/annotated/install-tools.sh)"
  exit 3
fi
mkdir -p "$ACXX_WORK/logs"

failures=0
note() { if [ "$1" -ne 0 ]; then failures=$((failures + 1)); fi; }

# The options every C file is verified with: -fno-strict-aliasing (the
# object words are typed by the chunks, not by C's effective types),
# -assume_left_to_right_evaluation (a call inside an expression, as the
# C++ writes it).
OPTS=(-fno-strict-aliasing -assume_left_to_right_evaluation)

# Every check runs as a parallel job (at most one per core); the output is
# printed in order at the end. A job's exit status is its failure count.
# Two phases: render.sh --check rewrites the 32-bit renderings (under
# $GEN32; the committed 64-bit ones it only compares), so it runs together
# with the LP64 proofs, and the ILP32 proofs and the mutants (which copy
# the 32-bit model) start when it is done.
JOBS="$ACXX_WORK/logs/run-jobs"
rm -rf "$JOBS"
mkdir -p "$JOBS"
MAXJOBS="${RUN_JOBS:-$(nproc)}"
njobs=0
pids=()
spawn() {
  while [ "$(jobs -rp | wc -l)" -ge "$MAXJOBS" ]; do wait -n; done
  ("$@") > "$JOBS/$njobs.log" 2>&1 &
  pids+=($!)
  njobs=$((njobs + 1))
}
# The second phase's jobs, in order, each as a quoted command line.
deferred=()
defer() {
  deferred+=("$(printf '%q ' "$@")")
}

# 1, 2.
render_check() {
  local f=0
  if ./render.sh --check > "$ACXX_WORK/logs/render.log" 2>&1; then
    printf 'ok    %-40s %s\n' render "$(grep -c '^ok' "$ACXX_WORK/logs/render.log") sidecars match the sources"
  else
    printf 'FAIL  %-40s\n' render
    grep -v '^ok' "$ACXX_WORK/logs/render.log" | head -20
    f=1
  fi
  ./constants-check.sh || f=$((f + 1))
  return $f
}
render_pid=""
if [ -z "$filter" ]; then
  spawn render_check
  render_pid="${pids[-1]}"
fi

# entry NAME EXPECT(pass|fail) EXPECTED-ERROR-REGEX FILE [EXTRA OPTIONS...]
# A generated FILE (*.gen.c) is verified for ILP32 in its 32-bit rendering.
# LP64 now, ILP32 in the second phase.
entry() {
  spawn entry_run LP64 "$@"
  defer entry_run ILP32 "$@"
}
entry_run() {
  local failures=0
  local only="$1"; shift
  local name="$1" expect="$2" pattern="$3" file="$4"; shift 4
  for target in "$only"; do
    local full="$name/$target"
    [[ -n "$filter" && "$full" != *"$filter"* ]] && continue
    local dir="$ANNOTATED_DIR"
    [[ "$target" = ILP32 && "$file" = *.gen.c ]] && dir="$GEN32"
    local out status start end
    start=$(date +%s%N)
    out=$(cd "$dir" && "$VERIFAST" -c -target "$target" "${OPTS[@]}" "$@" "$file" 2>&1)
    status=$?
    end=$(date +%s%N)
    local verdict=pass
    [ $status -ne 0 ] && verdict=fail
    local first
    first=$(echo "$out" | grep -m1 -E "error|errors found" || true)
    local t
    t=$(printf '%d.%02d s' $(((end - start) / 1000000000)) $((((end - start) / 10000000) % 100)))
    if [ "$verdict" = "$expect" ] && { [ "$expect" = pass ] || echo "$first" | grep -qE "$pattern"; }; then
      printf 'ok    %-40s %s %s: %s\n' "$full" "$verdict" "$t" "$first"
    else
      printf 'FAIL  %-40s %s (expected %s %s): %s\n' "$full" "$verdict" "$expect" "$pattern" "$first"
      failures=$((failures + 1))
    fi
  done
  return $failures
}

# mutant NAME SIDECAR SOURCE PATTERN "VERIFAST OPTIONS" FROM TO [FROM TO]...
mutant() {
  [ "$QUICK" = 1 ] && return
  [[ -n "$filter" && "$1" != *"$filter"* ]] && return
  defer ./mutant.sh "$@"
}

# The correspondence check's self-tests: a rendered function changed in the
# source only (an off-by-one in a bound; a strict comparison made non-strict) must
# fail as drift.
mutant drift-encoder encoder/message_encoder.render src/messaging.cc DRIFT "" \
  "to > object->length()) return false;" "to > object->length() + 1) return false;"
mutant drift-utf8 utf8/utf_8_to_16.render src/utils.cc DRIFT "" \
  "    if (c < 0x10000) {" "    if (c <= 0x10000) {"

# 3. The renderings.
entry translator-rules      pass "" tests/rules.gen.c -allow_dead_code
# The closure rules' checks (a captured reference is rendered as a copy of
# the value): each change makes the copy differ from the reference and must
# stop the translator. The lambda writes its capture; the enclosing
# function takes a captured variable's address; the statement that creates
# the lambda assigns a captured variable; the template instance keeps a
# copy of the closure.
RULES_CC=verified/cxx/annotated/tests/rules.cc
mutant closure-lambda-writes tests/rules.render $RULES_CC "RENDER:the lambda .* uses the captured base" "" \
  "{ return base; });" "{ return base = 0; });"
mutant closure-address-taken tests/rules.render $RULES_CC "RENDER:the enclosing function uses the captured base" "" \
  "  base = first;\n" "  word* alias = &base;\n  *alias = first;\n"
mutant closure-statement-assigns tests/rules.render $RULES_CC "RENDER:the statement creating .* uses the captured b" "" \
  "word first = retry_once(1, [&]() -> word" "word first = retry_once(b = 1, [&]() -> word"
mutant closure-escapes tests/rules.render $RULES_CC "RENDER:closure parameter produce is used other than called" "" \
  "static word retry_once(word n, F produce) {\n  word result = produce();" \
  "static word retry_once(word n, F produce) {\n  F copy = produce;\n  word result = copy();" \
  "SIDECAR::use_lambdas#1@@  word result = produce();" "  F copy = produce;\n  word result = copy();" \
  "SIDECAR::use_lambdas#2@@  word result = produce();" "  F copy = produce;\n  word result = copy();"
entry model                 pass "" model/objects.gen.c
mutant program-class-id-slot model/objects.render src/program.h "Cannot prove" "" \
  "return _builtin_class_ids[index];" "return _builtin_class_ids[0];"
mutant program-heap-end model/objects.render src/process.h "Cannot prove" "" \
  "address - start < program_heap_size_" "address - start <= program_heap_size_"
mutant program-heap-before-start model/objects.render src/process.h "underflow|Cannot prove" "" \
  "address >= start && address - start" "address - start"
mutant program-heap-pages model/objects.render src/flash_allocation.h "Cannot prove" "" \
  "size_in_pages_ << FLASH_PAGE_SIZE_LOG2" "size_in_pages_ * 2048"
mutant program-heap-empty model/objects.render src/process.cc "Cannot prove" "" \
  "program ? program->size_no_assets() : 0" "program ? program->size_no_assets() : 1"
mutant byte-array-external-length model/objects.render src/objects.h "Cannot prove.*o_len" "" \
  "return -1 - static_cast<word>(UINTPTR_MAX - bits);" "return -static_cast<word>(UINTPTR_MAX - bits);"
entry gc-mark-roots         pass "" heap/mark_roots.gen.c
mutant gc-mark-roots-capacity heap/mark_roots.render src/third_party/dartino/mark_sweep.h 'Cannot prove|No matching' "" \
  'if (next_ < limit_)' 'if (next_ <= limit_)'
mutant gc-mark-roots-first-visit heap/mark_roots.render src/third_party/dartino/mark_sweep.h 'Cannot prove|No matching' "" \
  'if (!GcMetadata::mark_grey_if_not_marked(heap_object))' 'if (GcMetadata::mark_grey_if_not_marked(heap_object))'
mutant gc-mark-roots-stack-start heap/mark_roots.render src/objects.cc 'Cannot prove|No matching' "" \
  'Object** roots = slots + top;' 'Object** roots = slots;'
mutant gc-mark-roots-bytecode-end heap/mark_roots.render src/objects.cc 'Cannot prove|No matching' "" \
  'if (value >= bytecodes_from && value < bytecodes_to) continue;' 'if (value >= bytecodes_from && value <= bytecodes_to) continue;'
mutant gc-mark-roots-object-size heap/mark_roots.render src/third_party/dartino/object_memory_mark_sweep.cc 'Cannot prove|No matching' "" \
  'GcMetadata::mark_all(object, object->size(program_));' 'GcMetadata::mark_all(object, WORD_SIZE);'
mutant gc-mark-roots-overflow heap/mark_roots.render src/third_party/dartino/mark_sweep.h 'Cannot prove|No matching' "" \
  'overflowed_ = true;' 'overflowed_ = false;'

entry gc-scavenge-chunk pass "" heap/scavenge_chunk.gen.c
mutant gc-scavenge-chunk-position heap/scavenge_chunk.render src/third_party/dartino/object_memory_copying.cc 'Cannot prove|cursor' "" \
  "chunk->set_scavenge_pointer(current);" "chunk->set_scavenge_pointer(start);"
mutant gc-scavenge-chunk-size heap/scavenge_chunk.render src/third_party/dartino/object_memory_copying.cc 'No matching|Cannot prove|overflow' "" \
  "current += object->size(program);" "current += WORD_SIZE;"
entry gc-scavenge-drain pass "" heap/scavenge_drain.gen.c
mutant gc-scavenge-drain-young heap/scavenge_drain.render src/third_party/dartino/two_space_heap.h 'Cannot prove|invariant' "" \
  "bool young_work = to_.complete_scavenge(this);" "bool young_work = false;"
mutant gc-scavenge-drain-last-chunk heap/scavenge_drain.render src/third_party/dartino/object_memory_copying.cc 'Cannot prove|invariant' "" \
  "if (scan_copied_chunk(program_, visitor, chunk)) found_work = true;" "found_work = scan_copied_chunk(program_, visitor, chunk);"
mutant gc-scavenge-drain-dummy-card heap/scavenge_drain.render src/third_party/dartino/object_memory_copying.cc 'record_|Cannot prove' "" \
  "visitor->set_record_to_dummy_address();" ""
mutant gc-scavenge-drain-old heap/scavenge_drain.render src/third_party/dartino/two_space_heap.h 'Cannot prove|invariant' "" \
  "work_found = young_work || old_work;" "work_found = young_work;"
mutant gc-scavenge-drain-detach heap/scavenge_drain.render src/third_party/dartino/object_memory_mark_sweep.cc 'tracking|promoted_track_|Cannot prove head.* == null_pointer' "" \
  "bool OldSpace::complete_scavenge(@@  promoted_track_ = null;" ""
mutant gc-scavenge-drain-card heap/scavenge_drain.render src/third_party/dartino/object_memory_mark_sweep.cc 'record_|card' "" \
  "static bool scan_promoted_track(@@    visitor->set_record_new_space_pointers(GcMetadata::remembered_set_for(object));" ""
mutant gc-scavenge-drain-links heap/scavenge_drain.render src/third_party/dartino/object_memory_mark_sweep.cc 'tracks|decreases|Cannot prove' "" \
  "bool OldSpace::complete_scavenge(@@    promoted = promoted->next();" "    promoted = null;"
entry gc-scavenge-roots pass "" heap/scavenge_roots.gen.c
mutant gc-scavenge-roots-allocate-charge heap/scavenge_roots.render src/third_party/dartino/object_memory.cc 'charged_bytes' "" \
  "allocated_ += size;" ""
mutant gc-scavenge-roots-allocate-refund heap/scavenge_roots.render src/third_party/dartino/object_memory.cc 'released_pages' "" \
  "OS::free_pages(memory, size);" ""
mutant gc-scavenge-roots-allocate-map heap/scavenge_roots.render src/third_party/dartino/object_memory.cc 'chunk_tables' "" \
  "GcMetadata::map_metadata_for_chunk(chunk);" ""
mutant gc-scavenge-roots-free-charge heap/scavenge_roots.render src/third_party/dartino/object_memory.cc 'debited_bytes' "" \
  "allocated_ -= chunk->size();" ""
mutant gc-scavenge-roots-free-order heap/scavenge_roots.render src/third_party/dartino/object_memory.cc 'debited_bytes' "" \
  "allocated_ -= chunk->size();\n  delete chunk;" "delete chunk;\n  allocated_ -= chunk->size();"
mutant gc-scavenge-roots-teardown-unlink heap/scavenge_roots.render src/third_party/dartino/object_memory.cc 'detached_chunk_links' "" \
  "chunk_list_.unlink(it);" ""
mutant gc-scavenge-roots-teardown-release heap/scavenge_roots.render src/third_party/dartino/object_memory.cc 'Cannot prove|leak' "" \
  "ObjectMemory::free_chunk(it);" ""
mutant gc-scavenge-roots-teardown-window heap/scavenge_roots.render src/third_party/dartino/object_memory.cc 'SemiSpace_limit_' "" \
  "void Space::free_all_chunks()@@  top_ = limit_ = 0;" "  top_ = 0;"
mutant gc-scavenge-roots-retire-type heap/scavenge_roots.render src/third_party/dartino/object_memory.cc 'Cannot prove|No matching' "" \
  "GcMetadata::mark_pages_for_chunk(this, UNKNOWN_SPACE_PAGE);" "GcMetadata::mark_pages_for_chunk(this, NEW_SPACE_PAGE);"
mutant gc-scavenge-roots-retire-size heap/scavenge_roots.render src/third_party/dartino/object_memory.cc 'reserved_pages|Cannot prove' "" \
  "OS::free_pages(reinterpret_cast<void*>(start_), size());" "OS::free_pages(reinterpret_cast<void*>(start_), 0);"
mutant gc-scavenge-roots-chunk-cursor heap/scavenge_roots.render src/third_party/dartino/object_memory.cc 'Cannot prove' "" \
  "scavenge_pointer_(start_)" "scavenge_pointer_(end_)"
mutant gc-scavenge-roots-chunk-range heap/scavenge_roots.render src/third_party/dartino/object_memory.cc 'invalid_chunk_abort|Cannot prove' "" \
  "if (!GcMetadata::in_metadata_range(start))" "if (GcMetadata::in_metadata_range(start))"
mutant gc-scavenge-roots-used heap/scavenge_roots.render src/third_party/dartino/object_memory_copying.cc 'Cannot prove' "" \
  "return (top() - chunk_list_.last()->start());" "return top();"
mutant gc-scavenge-roots-remove-owner heap/scavenge_roots.render src/third_party/dartino/object_memory.h 'owner_|classified_pages|Cannot prove' "" \
  "if (chunk) chunk->set_owner(nullptr);" ""
mutant gc-scavenge-roots-survivor-owner heap/scavenge_roots.render src/third_party/dartino/object_memory.h 'Cannot prove' "" \
  "chunk->owner_ = this;" "chunk->owner_ = &source;"
mutant gc-scavenge-roots-survivor-window heap/scavenge_roots.render src/third_party/dartino/object_memory.h 'Cannot prove' "" \
  "top_ = source.top_;" "top_ = source.limit_;"
mutant gc-scavenge-roots-chunk-link heap/scavenge_roots.render src/third_party/dartino/object_memory_copying.cc 'No matching.*single_chunk' "" \
  "void SemiSpace::append(@@  chunk_list_.append(chunk);" ""
mutant gc-scavenge-roots-space-type heap/scavenge_roots.render src/third_party/dartino/object_memory_copying.cc 'Cannot prove' "" \
  "page_type_(page_type)" "page_type_(UNKNOWN_SPACE_PAGE)"
mutant gc-scavenge-roots-mark-extent heap/scavenge_roots.render src/third_party/dartino/gc_metadata.h 'Cannot prove|No matching' "" \
  "uword size = chunk->size() >> MARK_BITS_SHIFT;" "uword size = chunk->size() >> (MARK_BITS_SHIFT + 1);"
mutant gc-scavenge-roots-page-index heap/scavenge_roots.render src/third_party/dartino/gc_metadata.h 'Cannot prove|No matching|overflow' "" \
  "page_type_bytes_ + (index >> TOIT_PAGE_SIZE_LOG2)" "page_type_bytes_ + (size >> TOIT_PAGE_SIZE_LOG2)"
mutant gc-scavenge-roots-overflow-scale heap/scavenge_roots.render src/third_party/dartino/gc_metadata.h 'Cannot prove' "" \
  "((address >> CARD_SIZE_IN_BITS_LOG_2) +" "((address >> CARD_SIZE_LOG_2) +"
mutant gc-scavenge-roots-owner-store heap/scavenge_roots.render src/third_party/dartino/object_memory.cc 'Cannot prove|No matching' "" \
  "owner_ = value;" "owner_ = null;"
mutant gc-scavenge-roots-overflow-init heap/scavenge_roots.render src/third_party/dartino/object_memory.cc 'Cannot prove' "" \
  "GcMetadata::initialize_overflow_bits_for_chunk(this);" ""
mutant gc-scavenge-roots-remembered-value heap/scavenge_roots.render src/third_party/dartino/gc_metadata.h 'Cannot prove' "" \
  "memset(from, GcMetadata::NO_NEW_SPACE_POINTERS, to - from);" "memset(from, GcMetadata::NEW_SPACE_POINTERS, to - from);"
mutant gc-scavenge-roots-remembered-live heap/scavenge_roots.render src/third_party/dartino/gc_metadata.h 'remembered_slice|No matching|Cannot prove' "" \
  'static void initialize_remembered_set_for_chunk@@start = only_above;' 'start = chunk->start();'
mutant gc-scavenge-roots-source-size heap/scavenge_roots.render src/third_party/dartino/two_space_heap.h 'Cannot prove.*size|Cannot prove.*(fe|fs)' "" \
  "from_size_(heap->new_space()->single_chunk_size())" "from_size_(to_chunk->size())"
mutant gc-scavenge-roots-window-start heap/scavenge_roots.render src/third_party/dartino/object_memory_copying.cc 'Cannot prove|No matching' "" \
  "update_base_and_limit(chunk, chunk->start());" "update_base_and_limit(chunk, chunk->end());"
mutant gc-scavenge-roots-stale-promotion heap/scavenge_roots.render src/third_party/dartino/two_space_heap.cc 'No matching.*copied_header\(original' "" \
  "*p = moved_object;" "*p = old_object;"
mutant gc-scavenge-roots-source-tag heap/scavenge_roots.render src/third_party/dartino/two_space_heap.h 'Cannot prove' "" \
  "if (is_smi(object)) return false;" ""
mutant gc-scavenge-roots-end heap/scavenge_roots.render src/third_party/dartino/two_space_heap.h 'Cannot prove' "" \
  " - to_start_ < to_size_;" " - to_start_ <= to_size_;"
mutant gc-scavenge-roots-skip heap/scavenge_roots.render src/third_party/dartino/two_space_heap.cc 'Cannot prove|No matching' "" \
  "scavenge_root(p);" ""
mutant gc-scavenge-roots-header-tag heap/scavenge_roots.render src/objects.h 'Cannot prove' "" \
  "return is_heap_object(_at(HEADER_OFFSET));" "return !is_heap_object(_at(HEADER_OFFSET));"
mutant gc-scavenge-roots-forwarded-card heap/scavenge_roots.render src/third_party/dartino/two_space_heap.cc 'Cannot prove' "" \
  "if (in_to_space(destination)) *record_" "if (!in_to_space(destination)) *record_"
mutant gc-scavenge-roots-promotion-request heap/scavenge_roots.render src/third_party/dartino/two_space_heap.cc 'Cannot prove' "" \
  "trigger_old_space_gc_ = true;" "trigger_old_space_gc_ = false;"
entry gc-scavenge-clone pass "" heap/scavenge_clone.gen.c
mutant gc-scavenge-clone-short heap/scavenge_clone.render src/third_party/dartino/two_space_heap.cc 'Cannot prove.*(object_size|result).*1' "" \
  "SOURCE::reinterpret_cast<void*>(original->_raw()), object_size);" "reinterpret_cast<void*>(original->_raw()), object_size - 1);" \
  "SIDECAR::type=HeapObject*(Program*,HeapObject*,toit::OldSpace*)@@reinterpret_cast<void*>(original->_raw()), object_size);" "reinterpret_cast<void*>(original->_raw()), object_size - 1);" \
  "SIDECAR::type=HeapObject*(Program*,HeapObject*,toit::SemiSpace*)@@reinterpret_cast<void*>(original->_raw()), object_size);" "reinterpret_cast<void*>(original->_raw()), object_size - 1);"
mutant gc-scavenge-clone-request heap/scavenge_clone.render src/third_party/dartino/two_space_heap.cc 'Cannot prove|No matching' "" \
  "SOURCE::to->allocate(object_size);" "to->allocate(object_size - WORD_SIZE);" \
  "SIDECAR::type=HeapObject*(Program*,HeapObject*,toit::OldSpace*)@@to->allocate(object_size);" "to->allocate(object_size - WORD_SIZE);" \
  "SIDECAR::type=HeapObject*(Program*,HeapObject*,toit::SemiSpace*)@@to->allocate(object_size);" "to->allocate(object_size - WORD_SIZE);"
mutant gc-scavenge-clone-forward heap/scavenge_clone.render src/third_party/dartino/two_space_heap.cc 'Cannot prove original == target' "" \
  "SOURCE::original->set_forwarding_address(target);" "original->set_forwarding_address(original);" \
  "SIDECAR::type=HeapObject*(Program*,HeapObject*,toit::OldSpace*)@@original->set_forwarding_address(target);" "original->set_forwarding_address(original);" \
  "SIDECAR::type=HeapObject*(Program*,HeapObject*,toit::SemiSpace*)@@original->set_forwarding_address(target);" "original->set_forwarding_address(original);"
entry scheduler-ready-dispatch pass "" heap/scheduler_ready.gen.c
mutant scheduler-ready-dispatch-count heap/scheduler_ready.render src/scheduler.cc 'Cannot prove.*length' "" \
  "Process* process = ready_queue_[i].remove_first();\n    ready_count_--;" "Process* process = ready_queue_[i].remove_first();\n    ready_count_ -= 0;"
entry scheduler-gc-workers pass "" heap/scheduler_workers.gen.c
mutant scheduler-gc-workers-count heap/scheduler_workers.render src/scheduler.cc 'Cannot prove.*count' "" \
  "running_process->signal(Process::PREEMPT);\n      count++;" "running_process->signal(Process::PREEMPT);\n      count--;"
mutant scheduler-gc-workers-wrong-ack heap/scheduler_workers.render src/scheduler.cc 'Cannot prove|No matching heap chunks: notifications' "" \
  "if (worker->take_gc_preemption_request() && gc_waiting_for_preemption_ > 0)" "if (!worker->take_gc_preemption_request() && gc_waiting_for_preemption_ > 0)"
entry scheduler-gc-targets pass "" heap/scheduler_targets.gen.c
mutant scheduler-gc-targets-scan heap/scheduler_targets.render src/scheduler.cc 'No matching heap chunks: scans' "" \
  "scan_gc_target(target, try_hard);" "scan_gc_target(target, !try_hard);"
mutant scheduler-gc-targets-resume heap/scheduler_targets.render src/scheduler.cc 'Cannot prove|No matching heap chunks: calls' "" \
  "if (target->state() != Process::SUSPENDED_AWAITING_GC)" "if (target->state() == Process::SUSPENDED_AWAITING_GC)"
mutant scheduler-gc-targets-invert-claim heap/scheduler_targets.render src/scheduler.cc 'Cannot prove append.*selected|No matching heap chunks: detached' "" \
  "if (claim_gc_target(locker, target, cross_owner))" "if (!claim_gc_target(locker, target, cross_owner))"
mutant scheduler-gc-targets-owner heap/scheduler_targets.render src/scheduler.cc 'No matching heap chunks: checks' "" \
  "if (claim_gc_target(locker, target, cross_owner))" "if (claim_gc_target(locker, target, !cross_owner))"
entry gc-process-root-lists pass "" heap/process_roots.gen.c
mutant gc-process-root-lists-count heap/process_roots.render src/heap.cc 'No matching heap chunks: visits' "" \
  "callback->do_roots(root->slot(), 1);" "callback->do_roots(root->slot(), 0);"
mutant gc-process-root-lists-slot heap/process_roots.render src/heap.cc 'No matching heap chunks: visits' "" \
  "callback->do_roots(global_variables_, program()->global_variables.length());" "callback->do_roots(reinterpret_cast<Object**>(&task_), program()->global_variables.length());"
entry gc-mark-process       pass "" heap/mark_process.gen.c
mutant gc-mark-process-deferred heap/mark_process.render src/third_party/dartino/object_memory_mark_sweep.cc 'Cannot prove|No matching' "" \
  'while (!is_empty() || is_overflowed())' 'while (!is_empty())'
mutant gc-mark-process-old-space heap/mark_process.render src/third_party/dartino/object_memory_mark_sweep.cc 'Cannot prove|No matching' "" \
  'old_space->iterate_overflowed_objects(visitor, this);' 'new_space->iterate_overflowed_objects(visitor, this);'
mutant gc-mark-process-no-clear heap/mark_process.render src/third_party/dartino/object_memory_mark_sweep.cc 'Cannot prove|No matching|decreases' "" \
  '      clear_overflow();' ''
entry gc-overflow-card      pass "" heap/overflow_card.gen.c
mutant gc-overflow-card-ignore-grey heap/overflow_card.render src/third_party/dartino/object_memory.cc 'Cannot prove|No matching' "" \
  'if (GcMetadata::is_grey(object)) {' 'if (!GcMetadata::is_grey(object)) {'
mutant gc-overflow-card-mark-size heap/overflow_card.render src/third_party/dartino/object_memory.cc 'Cannot prove|No matching' "" \
  'GcMetadata::mark_all(object, object->size(program));' 'GcMetadata::mark_all(object, WORD_SIZE);'
entry gc-compaction-object-move pass "" heap/object_move.gen.c -prover z3v4.5
mutant gc-compaction-object-move-header heap/object_move.render src/third_party/dartino/object_memory_mark_sweep.cc 'Cannot prove|No matching' "-prover z3v4.5" \
  '*reinterpret_cast<uword*>(dest) = t0;' '*reinterpret_cast<uword*>(dest) = 0;'
mutant gc-compaction-object-move-tail heap/object_move.render src/third_party/dartino/object_memory_mark_sweep.cc 'Cannot prove|No matching' "-prover z3v4.5" \
  '*reinterpret_cast<uword*>(dest) = *reinterpret_cast<uword*>(source);' '*reinterpret_cast<uword*>(dest) = t0;'
entry gc-compaction-root-walk pass "" heap/fix_roots.gen.c
mutant gc-compaction-root-walk-store heap/fix_roots.render src/third_party/dartino/object_memory_mark_sweep.cc 'Cannot prove|No matching' "" \
  '*current = HeapObject::from_address(destination);' '*current = object;'
entry gc-stack-relocate     pass "" heap/stack_relocate.gen.c
entry gc-stack-fill         pass "" heap/stack_fill.gen.c
mutant gc-stack-fill-header heap/stack_fill.render src/utils.h 'Cannot prove|No matching' "" \
  'data[i] = value;' 'data[i] = 0;'
entry gc-bitmap-fill        pass "" heap/mark_bits.gen.c
mutant gc-bitmap-fill-value heap/mark_bits.render src/utils.h 'Cannot prove|No matching' "" \
  'data[i] = value;' 'data[i] = 0;'
entry free-list-search      pass "" heap/free_list.gen.c
mutant free-list-search-clear heap/free_list.render src/third_party/dartino/object_memory.h 'Cannot prove|No matching' "" \
  'void clear()@@for (int i = 0; i < NUMBER_OF_BUCKETS; i++)' 'for (int i = 0; i < NUMBER_OF_BUCKETS - 1; i++)'
mutant free-list-search-highest heap/free_list.render src/third_party/dartino/object_memory.h 'Cannot prove|No matching' "" \
  'int i = NUMBER_OF_BUCKETS - 1; i >= smallest_bucket' 'int i = NUMBER_OF_BUCKETS - 2; i >= smallest_bucket'
mutant free-list-search-flush-trim heap/free_list.render src/third_party/dartino/object_memory_mark_sweep.cc 'track_end|Cannot prove|No matching' "" \
  "void OldSpace::flush(@@      promoted_track_->set_end(top_);" "      promoted_track_->set_end(limit_);"
mutant free-list-search-unlink heap/free_list.render src/third_party/dartino/object_memory.h 'Cannot prove|No matching' "" \
  'previous->set_next_region(current->next_region());' 'previous->set_next_region(null);'
mutant free-list-search-track-size heap/free_list.render src/third_party/dartino/object_memory_mark_sweep.cc 'Cannot prove|No matching' "" \
  'tracking_allocations_ ? size + PromotedTrack::header_size() : size' 'size'
mutant free-list-search-flush-charge heap/free_list.render src/third_party/dartino/object_memory_mark_sweep.cc 'Cannot prove' "" \
  'used_ -= free_size;' 'used_ -= 0;'
mutant free-list-search-insert heap/free_list.render src/third_party/dartino/object_memory.h 'Cannot prove|No matching' "" \
  'result->set_next_region(buckets_[bucket]);' 'result->set_next_region(null);'

entry semispace             pass "" heap/semispace.gen.c -prover z3v4.5
entry card-barrier pass "" heap/remembered_card.gen.c -prover z3v4.5
mutant card-barrier-mark heap/remembered_card.render src/third_party/dartino/gc_metadata.h 'Cannot prove|No matching' "-prover z3v4.5" \
  '*reinterpret_cast<uint8*>(mark_byte) = NEW_SPACE_POINTERS;' '*reinterpret_cast<uint8*>(mark_byte) = NO_NEW_SPACE_POINTERS;'
mutant card-barrier-read heap/remembered_card.render src/third_party/dartino/gc_metadata.h 'Cannot prove' "-prover z3v4.5" \
  'return *reinterpret_cast<uint8*>(address) != NO_NEW_SPACE_POINTERS;' 'return *reinterpret_cast<uint8*>(address) == NO_NEW_SPACE_POINTERS;'
entry young-allocation      pass "" heap/young_allocation.gen.c -prover z3v4.5
mutant young-allocation-size heap/young_allocation.render src/heap.h 'No matching heap chunks|Cannot prove' "-prover z3v4.5" \
  'return two_space_heap_.allocate(byte_size);' 'return two_space_heap_.allocate(WORD_SIZE);'
mutant young-allocation-retry-charge heap/young_allocation.render src/third_party/dartino/two_space_heap.cc 'No matching heap chunks: record_request' "-prover z3v4.5" \
  'record_direct_old_allocation(result, size);' 'record_direct_old_allocation(result, WORD_SIZE);'
mutant young-allocation-retry-no-mark heap/young_allocation.render src/third_party/dartino/two_space_heap.cc 'No matching|Cannot prove' "-prover z3v4.5" \
  'GcMetadata::insert_into_remembered_set(address);' ''
mutant young-allocation-retry-no-charge heap/young_allocation.render src/third_party/dartino/two_space_heap.cc 'charged' "-prover z3v4.5" \
  'total_bytes_allocated_.fetch_add(size, std::memory_order_relaxed);' ''
mutant young-allocation-retry-order heap/young_allocation.render src/third_party/dartino/two_space_heap.cc 'RENDER:unsupported atomic fetch_add' "" \
  'total_bytes_allocated_.fetch_add(size, std::memory_order_relaxed);' 'total_bytes_allocated_.fetch_add(size, std::memory_order_release);'
mutant semispace-starts-bias heap/semispace.render src/third_party/dartino/gc_metadata.h 'No matching heap chunks' "-prover z3v4.5" \
  "singleton_.starts_bias_);" "singleton_.remembered_set_bias_);"
mutant semispace-range-end heap/semispace.render src/third_party/dartino/gc_metadata.h 'Cannot prove' "-prover z3v4.5" \
  "address <= lowest + singleton_.heap_extent_" "address < lowest + singleton_.heap_extent_"
mutant semispace-old-chunk-order heap/semispace.render src/third_party/dartino/object_memory_mark_sweep.cc 'promotion_metadata|No matching heap chunks' "-prover z3v4.5" \
  'append(chunk);\n    use_whole_chunk(chunk);' 'use_whole_chunk(chunk);\n    append(chunk);'
mutant semispace-free-region-request heap/semispace.render src/third_party/dartino/object_memory_mark_sweep.cc 'No matching heap chunks|Cannot prove' "-prover z3v4.5" \
  'return allocate_in_free_region(region, size);' 'return allocate_in_free_region(region, WORD_SIZE);'
mutant semispace-free-region-charge heap/semispace.render src/third_party/dartino/object_memory_mark_sweep.cc 'Cannot prove|No matching' "-prover z3v4.5" \
  'used_ += region->size();' 'used_ += size;'
mutant semispace-free-region-limit heap/semispace.render src/third_party/dartino/object_memory_mark_sweep.cc 'Cannot prove|No matching' "-prover z3v4.5" \
  'limit_ = top_ + region->size();' 'limit_ = top_ + size;'
mutant semispace-old-exact-fit heap/semispace.render src/third_party/dartino/object_memory_mark_sweep.cc 'old_sources|Cannot prove|No matching' "-prover z3v4.5" \
    'if (limit_ - top_ >= static_cast<uword>(size))' 'if (limit_ - top_ > static_cast<uword>(size))'
mutant semispace-old-start-byte heap/semispace.render src/third_party/dartino/gc_metadata.h 'Cannot prove' "-prover z3v4.5" \
    'static_cast<uint8>(address % 256)' 'static_cast<uint8>(address % 128)'
mutant semispace-sentinel-room heap/semispace.render src/third_party/dartino/object_memory.h "overflow|Cannot prove|No matching" "-prover z3v4.5" \
  "if (limit_ - top_ <= size)" "if (limit_ - top_ < size)"
mutant boxed-integer-value model/objects.render src/objects.h "Cannot prove|No matching heap chunks" "" \
  "_int64_at_put(VALUE_OFFSET, value);" "_int64_at_put(VALUE_OFFSET, 0);"
mutant semispace-failure-sentinel heap/semispace.render src/third_party/dartino/object_memory_copying.cc "No matching heap chunks|Cannot prove" "-prover z3v4.5" \
  "uword SemiSpace::allocate(uword size)@@    flush();" ""
mutant semispace-card-count heap/semispace.render src/third_party/dartino/gc_metadata.h "No matching heap chunks|Cannot prove|overflow" "-prover z3v4.5" \
  "memset(from, NO_OBJECT_START, cards);" "memset(from, NO_OBJECT_START, cards + 1);"
mutant semispace-install-sentinel heap/semispace.render src/third_party/dartino/object_memory_copying.cc "Cannot prove|No matching heap chunks" "-prover z3v4.5" \
  "void SemiSpace::update_base_and_limit(Chunk* chunk, uword top)@@  write_sentinel_at(top_);" ""
mutant semispace-old-chunk-limit heap/semispace.render src/third_party/dartino/object_memory_mark_sweep.cc "Cannot prove|No matching" "-prover z3v4.5" \
  "limit_ = top_ + chunk->size() - WORD_SIZE;" "limit_ = top_ + chunk->size();"
mutant semispace-old-chunk-track heap/semispace.render src/third_party/dartino/object_memory_mark_sweep.cc "Cannot prove|No matching" "-prover z3v4.5" \
  "void OldSpace::use_whole_chunk(Chunk* chunk)@@    top_ += PromotedTrack::header_size();" ""
# Check the shared arithmetic definitions against each target's imported
# contracts, then compare the deployed C++ functions with those definitions.
spawn entry_run LP64 smi-contract pass "" model/smi.c -I "$ANNOTATED_DIR/model" -prover z3v4.5
defer entry_run ILP32 smi-contract pass "" model/smi.c -I "$GEN32/model" -prover z3v4.5
cpp_equivalence() {
  local name="$1/$2" bits="$3" harness="$4"
  [[ -n "$filter" && "$name" != *"$filter"* ]] && return 0
  source ../env.sh
  if [ ! -x "$ESBMC" ]; then
    echo "FAIL  $name requires ESBMC (verified/cxx/install-tools.sh esbmc)"
    return 1
  fi
  local log="$ACXX_WORK/logs/$1-$bits.log"
  shift 4
  if "$ESBMC" "../harness/$harness.cc" "${CXXV_FLAGS[@]}" --std c++11 -DTOIT_VERIFIED_CORE \
      "--$bits" "-DCXXV_WORD_BITS=$bits" --overflow-check "$@" > "$log" 2>&1; then
    printf 'ok    %-40s %s\n' "$name" "$(grep 'properties failed' "$log")"
  else
    printf 'FAIL  %-40s see %s\n' "$name" "$log"
    return 1
  fi
}
finalizer_unlink_code() {
  local name="finalizer-unlink-code/$1"
  [[ -n "$filter" && "$name" != *"$filter"* ]] && return 0
  local options=()
  (( QUICK )) || options+=(--mutant)
  ./prims/check-finalizer-unlink.sh "$1" "${options[@]}" || { echo "FAIL  $name"; return 1; }
}
spawn finalizer_unlink_code LP64
defer finalizer_unlink_code ILP32
spawn cpp_equivalence finalizer-prepend LP64 64 finalizer_prepend
spawn cpp_equivalence finalizer-prepend ILP32 32 finalizer_prepend
spawn cpp_equivalence finalizer-queue LP64 64 finalizer_queue --unwind 4
spawn cpp_equivalence finalizer-queue ILP32 32 finalizer_queue --unwind 4
spawn cpp_equivalence gc-callable-finalizer LP64 64 gc_callable_finalizer --unwind 3
spawn cpp_equivalence gc-callable-finalizer ILP32 32 gc_callable_finalizer --unwind 3
for kind in RAW STRING_BUFFER NULL_BUFFER MAPPED; do
  spawn cpp_equivalence "gc-external-finalizer-${kind,,}" LP64 64 gc_external_finalizer "-DCXXV_STORAGE_KIND=$kind" --unwind 2 --memory-leak-check
  spawn cpp_equivalence "gc-external-finalizer-${kind,,}" ILP32 32 gc_external_finalizer "-DCXXV_STORAGE_KIND=$kind" --unwind 2 --memory-leak-check
done
spawn cpp_equivalence finalizer-header LP64 64 finalizer_header
spawn cpp_equivalence finalizer-header ILP32 32 finalizer_header
spawn cpp_equivalence spawn-method-views LP64 64 spawn_method_views
spawn cpp_equivalence spawn-method-views ILP32 32 spawn_method_views
spawn cpp_equivalence v2-table-bounds LP64 64 v2_table_bounds
spawn cpp_equivalence v2-table-bounds ILP32 32 v2_table_bounds
spawn cpp_equivalence v2-table-install LP64 64 v2_table_install --memory-leak-check
spawn cpp_equivalence v2-table-install ILP32 32 v2_table_install --memory-leak-check
spawn cpp_equivalence v2-table-compute LP64 64 v2_table_compute
spawn cpp_equivalence v2-table-compute ILP32 32 v2_table_compute
spawn cpp_equivalence event-notifiers LP64 64 event_notifiers
spawn cpp_equivalence event-notifiers ILP32 32 event_notifiers
spawn cpp_equivalence event-read-state LP64 64 event_read_state
spawn cpp_equivalence event-read-state ILP32 32 event_read_state
timer_arm() {
  local abi="$1" bits="$2" inc="$ACXX_WORK/timer-arm-$2"
  [[ -n "$filter" && "timer-arm/$abi" != *"$filter"* ]] && return 0
  mkdir -p "$inc" || return 1
  # ESBMC crashes instantiating Resource::as<Timer*> in this callback.
  # Expand only the checked single-cast definition from resource.h.
  grep -Fxq '  T as() { return static_cast<T>(this); }' "$REPO_ROOT/src/resource.h" || return 1
  awk '/^void TimerEventSource::arm\(/ { active=1; arm++ }
       /^void TimerEventSource::on_unregister_resource\(/ { active=1; unregister++ }
       active { casts += sub(/r->as<Timer\*>\(\)/, "static_cast<Timer*>(r)"); print }
       active && /^}$/ { active=0 }
       END { if (casts != 1 || arm != 1 || unregister != 1 || active) exit 1 }' "$REPO_ROOT/src/event_sources/timer.cc" > "$inc/timer_queue.inc" || return 1
  cpp_equivalence timer-arm "$abi" "$bits" timer_arm "-I$inc" --unwind 4 --unwindsetname __memcpy_impl:0:9
}
spawn timer_arm LP64 64
spawn timer_arm ILP32 32
timer_dispatch() {
  local abi="$1" bits="$2" inc="$ACXX_WORK/timer-dispatch-$2"
  [[ -n "$filter" && "timer-dispatch/$abi" != *"$filter"* ]] && return 0
  mkdir -p "$inc" || return 1
  awk '/^void TimerEventSource::entry\(/ { active=1; entry++ }
       /^void EventSource::dispatch\(const Locker/ { active=1; dispatch++ }
       /^void EventSource::try_notify\(/ { active=1; notify++ }
       active { observed += sub(/dispatch\(locker, next, 0\)/, "checked_dispatch(locker, next, 0)");
                round += sub(/while \(!stop_\)/, "while (!stop_ ? begin_timer_round() : false)"); print }
       active && /^}$/ { active=0 }
       END { if (entry != 1 || dispatch != 1 || notify != 1 || observed != 1 || round != 1 || active) exit 1 }' \
      "$REPO_ROOT/src/event_sources/timer.cc" "$REPO_ROOT/src/resource.cc" > "$inc/timer_dispatch.inc" || return 1
  cpp_equivalence timer-dispatch "$abi" "$bits" timer_dispatch "-I$inc" --unwind 3
}
spawn timer_dispatch LP64 64
spawn timer_dispatch ILP32 32
freertos_wait() {
  local abi="$1" bits="$2" inc="$ACXX_WORK/freertos-wait-$2"
  [[ -n "$filter" && "freertos-wait/$abi" != *"$filter"* ]] && return 0
  mkdir -p "$inc" || return 1
  awk '/^  bool wait_us\(int64 us\)/ { active=1; found++ }
       active { print }
       active && /^  }$/ { active=0 }
       END { if (found != 1 || active) exit 1 }' "$REPO_ROOT/src/os_freertos.h" > "$inc/freertos_wait.inc" || return 1
  cpp_equivalence freertos-wait "$abi" "$bits" freertos_wait "-I$inc"
}
spawn freertos_wait ILP32 32
freertos_chunk_admission() {
  local inc="$ACXX_WORK/freertos-chunk"
  [[ -n "$filter" && "freertos-chunk-admission/ILP32" != *"$filter"* ]] && return 0
  mkdir -p "$inc" || return 1
  awk '/^Chunk\* ObjectMemory::allocate_chunk\(/ { active=1; found++ }
       active { print }
       active && /^}$/ { active=0 }
       END { if (found != 1 || active) exit 1 }' "$REPO_ROOT/src/third_party/dartino/object_memory.cc" > "$inc/chunk_admission.inc" || return 1
  cpp_equivalence freertos-chunk-admission ILP32 32 freertos_chunk_admission "-I$inc" -DTOIT_FREERTOS --unwind 51
}
spawn freertos_chunk_admission
device_page_backend() {
  local platform="$1" name="gc-pages-$1" inc="$ACXX_WORK/gc-pages-$1"
  [[ -n "$filter" && "$name/ILP32" != *"$filter"* ]] && return 0
  mkdir -p "$inc" || return 1
  local flags=()
  if [[ "$platform" == esp32 ]]; then
    flags+=(-DCXXV_ESP32)
    awk '/^#define MALLOC_CAP_(8BIT|DMA|SPIRAM|INTERNAL) / { print; n++ }
         /^#define MALLOC_OPTION_THREAD_TAG / { if (tag && tag != $3) exit 1; if (!tag) print; tag=$3 }
         END { if (n != 4 || !tag) exit 1 }' "$REPO_ROOT/third_party/esp-idf/components/heap/include/esp_heap_caps.h" > "$inc/capabilities.inc" || return 1
  fi
  awk -v esp="$platform" '
    /^bool OS::use_spiram_for_(heap|metadata)_ =|^static const int (EXTERNAL_CAPS|INTERNAL_CAPS) =/ { print; constants++ }
    /^(void\*|void|bool|int) OS::(allocate_pages|free_pages|grab_virtual_memory|ungrab_virtual_memory|use_virtual_memory|unuse_virtual_memory|toit_heap_caps_flags_for_heap|toit_heap_caps_flags_for_metadata)\(/ { active=1; n++ }
    /^(void|word) OS::(get_heap_tag|set_heap_tag)\(.*\) \{$/ { active=1; tags++ }
    active { print }
    active && (/^}/ || /^void OS::unuse_virtual_memory.*{}$/) { active=0 }
    END { if (active || tags != 2 || n != (esp == "esp32" ? 8 : 6) || constants != (esp == "esp32" ? 4 : 0)) exit 1 }
  ' "$REPO_ROOT/src/os_$platform.cc" > "$inc/page_backend.inc" || return 1
  cpp_equivalence "$name" ILP32 32 device_page_backend "-I$inc" -DTOIT_FREERTOS "${flags[@]}"
}
spawn device_page_backend esp32
spawn device_page_backend ec618
ec618_heap_range() {
  local name=gc-heap-range-ec618 inc="$ACXX_WORK/gc-heap-range-ec618"
  [[ -n "$filter" && "$name/ILP32" != *"$filter"* ]] && return 0
  mkdir -p "$inc" || return 1
  awk '/^OS::HeapMemoryRange OS::get_heap_memory_range\(/ { active=1; n++ }
       active { print }
       active && /^}$/ { active=0 }
       END { if (n != 1 || active) exit 1 }' "$REPO_ROOT/src/os_ec618.cc" > "$inc/heap_range.inc" || return 1
  awk '/^(static int ensure_heap_initialized|size_t xPortGetTotalHeapSize)\(/ { active=1; n++ }
       active { print }
       active && /^}$/ { active=0 }
       END { if (n != 2 || active) exit 1 }' "$REPO_ROOT/toolchains/ec618/project/src/heap_7.c" > "$inc/port_init.inc" || return 1
  awk '/^(void \*(pvPortMallocEC|pvPortReallocEC|pvPortMemalign)|void vPortFree)\(/ { active=1; n++ }
       active { print }
       active && /^}$/ { active=0 }
       END { if (n != 4 || active) exit 1 }' "$REPO_ROOT/toolchains/ec618/project/src/heap_7.c" > "$inc/port_alloc.inc" || return 1
  awk '/^void vPortGetHeapStats\(/ { active=1; n++ }
       active { print }
       active && /^}$/ { active=0 }
       END { if (n != 1 || active) exit 1 }' "$REPO_ROOT/toolchains/ec618/project/src/heap_7.c" > "$inc/port_stats.inc" || return 1
  awk '/^typedef struct \{/ { body=$0; next }
       body { body=body "\n" $0 }
       /^}/ { if (/^} heap_stats_t;/ && body) { print body; n++ } body="" }
       END { if (n != 1) exit 1 }' "$REPO_ROOT/third_party/luatos-soc-ec618/PLAT/os/freertos/inc/portable.h" > "$inc/stats_type.inc" || return 1
  cpp_equivalence "$name" ILP32 32 ec618_heap_range "-I$inc" -DTOIT_FREERTOS \
    "-I$REPO_ROOT/toolchains/ec618/project/src/cmpctmalloc"
}
spawn ec618_heap_range
ec618_thread_map_source() {
  local inc="$1"
  awk '/^#define CONFIG_TOIT_EC618_MAX_THREADS / {print; n++}
       END {if (n != 1) exit 1}' "$REPO_ROOT/toolchains/ec618/ec618_config.h" > "$inc/thread_map.inc" || return 1
  awk '/^class InterruptMaskGuard \{|^struct ThreadMapEntry \{|^static (Thread\* get_current_thread|void (set|clear)_current_thread)\(/ {active=1; n++}
       /^static (ThreadMapEntry thread_map|ThreadMapEntry\* cached_thread_entry)/ {print; globals++}
       active {print}
       active && /^};?$/ {active=0}
       END {if (active || n != 5 || globals != 2) exit 1}' "$REPO_ROOT/src/os_ec618.cc" >> "$inc/thread_map.inc" || return 1
}
ec618_thread_spawn() {
  local name=ec618-thread-spawn inc="$ACXX_WORK/ec618-thread-spawn"
  [[ -n "$filter" && "$name/ILP32" != *"$filter"* ]] && return 0
  mkdir -p "$inc" || return 1
  awk '/^const int DEFAULT_STACK_SIZE =/ {print; constants++}
       /^struct ThreadData \{|^Thread::Thread\(|^bool Thread::spawn\(|^void\* thread_start\(|^static void ec618_thread_start\(|^void Thread::(_boot|run|join)\(|^Thread\* Thread::current\(/ {active=1; n++}
       active {print}
       active && (/^};?$/ || /locker_\(null\) \{\}$/) {active=0}
       END {if (active || n != 9 || constants != 1) exit 1}' "$REPO_ROOT/src/os_ec618.cc" > "$inc/thread_spawn.inc" || return 1
  ec618_thread_map_source "$inc" || return 1
  cpp_equivalence "$name" ILP32 32 ec618_thread_spawn "-I$inc" -DTOIT_FREERTOS --memory-leak-check
}
spawn ec618_thread_spawn
event_worker_start() {
  local name=ec618-event-worker-start inc="$ACXX_WORK/ec618-event-worker-start"
  [[ -n "$filter" && "$name/ILP32" != *"$filter"* ]] && return 0
  mkdir -p "$inc" || return 1
  awk '/^  static Ec618EventSource\* instance\(\)/ {print; n++} END {if (n != 1) exit 1}' \
      "$REPO_ROOT/src/event_sources/uart_ec618.h" > "$inc/event_worker_instance.inc" || return 1
  awk '/^TimerEventSource::TimerEventSource\(|^Ec618EventSource::(~?Ec618EventSource)\(|^void Ec618EventSource::(entry|send_event|send_event_from_isr)\(/ {active=1; n++}
       active {print} active && /^}$/ {active=0}
       END {if (active || n != 6) exit 1}' "$REPO_ROOT/src/event_sources/timer.cc" \
       "$REPO_ROOT/src/event_sources/uart_ec618.cc" > "$inc/event_worker_start.inc" || return 1
  cpp_equivalence "$name" ILP32 32 event_worker_start "-I$inc" --unwind 35
}
spawn event_worker_start
spawn cpp_equivalence ec618-mailbox ILP32 32 ec618_mailbox --unwind 11
spawn cpp_equivalence ec618-mailbox-race ILP32 32 ec618_mailbox_race
ec618_thread_map() {
  local name=ec618-thread-map inc="$ACXX_WORK/ec618-thread-map"
  [[ -n "$filter" && "$name/ILP32" != *"$filter"* ]] && return 0
  mkdir -p "$inc" || return 1
  ec618_thread_map_source "$inc" || return 1
  cpp_equivalence "$name" ILP32 32 ec618_thread_map "-I$inc" --unwind 17
}
spawn ec618_thread_map
ec618_arena_types() {
  local source="$1" inc="$2"
  awk '/^#define (ROUND_UP\(|ROUND_DOWN\(|HEAP_ALLOC_VIRTUAL_BITS |NUMBER_OF_BUCKETS |PAGE_SIZE_SHIFT |PAGE_SIZE )/ {print; macros++}
       /^typedef struct (header_struct|free_struct|Page|arena_struct) \{|^struct multi_heap_info \{/ {active=1; structs++}
       active {print}
       active && /^}/ {active=0}
       END {if (active || macros != 6 || structs != 5) exit 1}' "$source" > "$inc/arena_types.inc" || return 1
}

ec618_arena_layout() {
  local name=gc-ec618-arena-layout inc="$ACXX_WORK/gc-ec618-arena-layout"
  [[ -n "$filter" && "$name/ILP32" != *"$filter"* ]] && return 0
  local source="$REPO_ROOT/toolchains/ec618/project/src/cmpctmalloc/cmpctmalloc.c"
  mkdir -p "$inc" || return 1
  ec618_arena_types "$source" "$inc" || return 1
  awk '/^cmpct_heap_t \*cmpct_register_impl\(/ {signature=1; next}
       signature && /^\{/ {active=1; signature=0; next}
       active && /^    cmpct_heap_t \*page_heap =/ {active=0; n++}
       active {print}
       END {if (active || signature || n != 1) exit 1}' "$source" > "$inc/arena_layout.inc" || return 1
  awk '/^static const size_t arena_overhead =/ {print; constants++}
       /^    cmpct_init\(page_heap\);/ {active=1; next}
       active && /^    return page_heap;/ {active=0; n++}
       active {print}
       END {if (active || constants != 1 || n != 1) exit 1}' "$source" > "$inc/arena_remainders.inc" || return 1
  cpp_equivalence "$name" ILP32 32 ec618_arena_layout "-I$inc" -DTOIT_FREERTOS \
    "-I$REPO_ROOT/toolchains/ec618/project/src/cmpctmalloc"
}
spawn ec618_arena_layout
ec618_arena_init() {
  local name=gc-ec618-arena-init inc="$ACXX_WORK/gc-ec618-arena-init"
  [[ -n "$filter" && "$name/ILP32" != *"$filter"* ]] && return 0
  local source="$REPO_ROOT/toolchains/ec618/project/src/cmpctmalloc/cmpctmalloc.c"
  mkdir -p "$inc" || return 1
  ec618_arena_types "$source" "$inc" || return 1
  awk '/^void cmpct_init\(cmpct_heap_t \*heap\)$/ {active=1; n++}
       active {print}
       active && /^}/ {active=0}
       END {if (n != 1 || active) exit 1}' "$source" > "$inc/cmpct_init.inc" || return 1
  awk '/^    cmpct_heap_t \*page_heap =/ {active=1; n++}
       active {print}
       /^    cmpct_init\(page_heap\);/ {active=0}
       END {if (active || n != 1) exit 1}' "$source" > "$inc/arena_init.inc" || return 1
  cpp_equivalence "$name" ILP32 32 ec618_arena_init "-I$inc" -DTOIT_FREERTOS \
    "-I$REPO_ROOT/toolchains/ec618/project/src/cmpctmalloc"
}
spawn ec618_arena_init
ec618_page_table() {
  local name=gc-ec618-page-table inc="$ACXX_WORK/gc-ec618-page-table"
  [[ -n "$filter" && "$name/ILP32" != *"$filter"* ]] && return 0
  mkdir -p "$inc" || return 1
  local source="$REPO_ROOT/toolchains/ec618/project/src/cmpctmalloc/cmpctmalloc.c"
  # Verify the board's enum, struct, predicates and function in one C translation unit.
  awk 'BEGIN { print "#include <stdint.h>"; print "#include <stddef.h>" }
       /^#define PAGE_SIZE(_SHIFT)? / {print; constants++}
       /^typedef enum \{/ { enum_text=$0; next }
       enum_text { enum_text=enum_text "\n" $0 }
       /^} page_use_t;/ && enum_text { print enum_text; enum_text=""; active=1; n++; next }
       /^}/ { enum_text="" }
       active && /^\/\/ Allocation arenas are linked/ { active=0 }
       active { print }
       active && /^static (void (page_statistics|fill_page_statuses)|size_t (page_allocation_bytes|free_page_prefix|first_free_page_run|page_growth_start|release_page_run))\(/ { scans++ }
       /^    initialize_page_table\(page_heap->pages, pages\);/ { calls++ }
       END { if (active || n != 1 || calls != 1 || constants != 2 || scans != 7) exit 1 }' "$source" > "$inc/page_table.c" || return 1
  cat "$ANNOTATED_DIR/heap/ec618_page_accounting.c" "$ANNOTATED_DIR/heap/ec618_page_extents.c" \
      "$ANNOTATED_DIR/heap/ec618_page_resize.c" >> "$inc/page_table.c" || return 1
  entry_run ILP32 "$name" pass "" "$inc/page_table.c" -prover z3v4.5
}
spawn ec618_page_table
ec618_clear_pages() {
  local name=gc-ec618-clear-pages inc="$ACXX_WORK/gc-ec618-clear-pages"
  [[ -n "$filter" && "$name/ILP32" != *"$filter"* ]] && return 0
  mkdir -p "$inc" || return 1
  awk 'BEGIN {print "#include <stddef.h>"}
       /^predicate cleared_words/ {print "/*@"; active=1; n++}
       active {print}
       active && /^}/ {active=0}
       END {if (active || n != 1) exit 1}' "$REPO_ROOT/toolchains/ec618/project/src/cmpctmalloc/cmpctmalloc.c" > "$inc/clear_pages.c" || return 1
  entry_run ILP32 "$name" pass "" "$inc/clear_pages.c" -prover z3v4.5
}
spawn ec618_clear_pages
ec618_cbmc() {
  local name="$1" inc="$2" harness="$3" unwind="$4"
  source ../env.sh
  local log="$ACXX_WORK/logs/$name-32.log"
  arm-none-eabi-gcc -std=c11 -E -mcpu=cortex-m3 -mthumb "-I$inc" \
    "-I$REPO_ROOT/toolchains/ec618/project/src/cmpctmalloc" "../harness/$harness.c" \
    -o "$inc/$harness.i" || return 1
  local -a solver_options=()
  local solver_tmp="${TMPDIR:-/tmp}"
  if [[ "$harness" == ec618_page_realloc_commit || "$harness" == ec618_thread_tags ]]; then
    solver_options+=(--slice-formula)
    if command -v cadical >/dev/null; then
      solver_options+=(--external-sat-solver cadical)
      solver_tmp="$inc"
    fi
  fi
  if TMPDIR="$solver_tmp" "$CBMC_BIN/cbmc" "$inc/$harness.i" --32 --unwinding-assertions --unwind "$unwind" "${solver_options[@]}" > "$log" 2>&1; then
    printf 'ok    %-40s %s\n' "$name/ILP32" "$(grep 'of .* failed' "$log")"
  else
    echo "FAIL  $name/ILP32 see $log"
    return 1
  fi
}
ec618_thread_tags() {
  local name=gc-ec618-thread-tags inc="$ACXX_WORK/gc-ec618-thread-tags"
  [[ -n "$filter" && "$name/ILP32" != *"$filter"* ]] && return 0
  local source="$REPO_ROOT/toolchains/ec618/project/src/cmpctmalloc/cmpctmalloc.c"
  mkdir -p "$inc" || return 1
  ec618_arena_types "$source" "$inc" || return 1
  awk '/^#define MAX_TAG_ENTRIES |^static struct .* tag_map\[MAX_TAG_ENTRIES\];/ {print; declarations++}
       /^static inline void multi_heap_(un)?lock\(|^static void (\*get_thread_tag|set_thread_tag)\(|^void (cmpct_set_option|\*cmpct_get_option)\(.*\)$/ {active=1; functions++}
       active {print}
       active && /^}/ {active=0}
       END {if (active || declarations != 2 || functions != 6) exit 1}' "$source" > "$inc/thread_tags.inc" || return 1
  awk '/^void (vPortSetHeapTag|\*vPortGetHeapTag)\(/ {active=1; n++}
       active {print}
       active && /^}/ {active=0}
       END {if (active || n != 2) exit 1}' "${source%/cmpctmalloc/*}/heap_7.c" >> "$inc/thread_tags.inc" || return 1
  ec618_cbmc "$name" "$inc" ec618_thread_tags 17
}
spawn ec618_thread_tags
ec618_buckets() {
  local name="gc-ec618-$1" inc="$ACXX_WORK/gc-ec618-$1"
  [[ -n "$filter" && "$name/ILP32" != *"$filter"* ]] && return 0
  local source="$REPO_ROOT/toolchains/ec618/project/src/cmpctmalloc/cmpctmalloc.c"
  mkdir -p "$inc" || return 1
  ec618_arena_types "$source" "$inc" || return 1
  awk '/^#define NATURAL_ALIGNMENT / { print; defines++ }
       /^IRAM_ATTR (inline )?static (int size_to_index_(helper|allocating|freeing)|void (set|clear)_free_list_bit|int find_nonempty_bucket)\(/ {active=1; n++}
       active {print}
       active && /^}/ {active=0}
       END {if (active || n != 6 || defines != 1) exit 1}' "$source" > "$inc/buckets.inc" || return 1
  awk '/^#define OBFUSCATE\(/ {print; defines++}
       /^static INLINE (size_t get_size|void set_sizes)\(|^IRAM_ATTR inline static size_t (tag_as_free|untag)\(|^IRAM_ATTR static void (create_free_area|unlink_free)\(|^IRAM_ATTR static void \*create_allocation_header\(/ {active=1; n++}
       active {print}
       active && /^}/ {active=0}
       END {if (active || n != 7 || defines != 1) exit 1}' "$source" > "$inc/bucket_links.inc" || return 1
  if [[ "$1" == stats || "$1" == stats_report ]]; then
    awk '/^typedef enum \{/ {body=$0; next}
         body {body=body "\n" $0}
         /^} page_use_t;/ && body {print body; n++}
         /^}/ {body=""}
         /^static void page_statistics\(/ {print "#ifndef EC618_PAGE_STATISTICS_CONTRACT"; scan=1; active=1; n++}
         /^void cmpct_get_info_impl\(/ {active=1; n++}
         active {print}
         active && /^}/ {active=0}
         scan && /^}/ {print "#endif"; scan=0}
         END {if (active || scan || n != 3) exit 1}' "$source" > "$inc/stats.inc" || return 1
    ec618_cbmc "$name" "$inc" "ec618_$1" 73
    return
  fi
  if [[ "$1" == realloc_dispatch ]]; then
    awk '/^#define MIN\(/ {print; defines++}
         /^IRAM_ATTR static void set_tag\(|^IRAM_ATTR void \*cmpct_realloc_impl\(/ {active=1; n++}
         active {print}
         active && /^}/ {active=0}
         END {if (active || n != 2 || defines != 1) exit 1}' "$source" > "$inc/realloc_dispatch.inc" || return 1
  fi
  if [[ "$1" == allocation_size ]]; then
    awk '/^static size_t page_allocation_bytes\(/ {active=1; n++}
         active {print}
         active && /^}/ {active=0}
         END {if (active || n != 1) exit 1}' "$source" > "$inc/allocation_span.inc" || return 1
    awk '/^typedef enum \{/ {body=$0; next}
         body {body=body "\n" $0}
         /^} page_use_t;/ && body {print body; n++}
         /^}/ {body=""}
         /^IRAM_ATTR static (size_t (allocation_size|page_number)|bool is_page_allocated)\(|^IRAM_ATTR size_t cmpct_get_allocated_size_impl\(/ {active=1; n++}
         active {print}
         active && /^}/ {active=0}
         END {if (active || n != 5) exit 1}' "$source" > "$inc/allocation_query.inc" || return 1
  fi
  if [[ "$1" == fragments ]]; then
    awk '/^static const size_t arena_overhead =/ {print; constants++}
         /^IRAM_ATTR static void add_to_heap\(|^void cmpct_init\(/ {active=1; n++}
         active {print}
         active && /^}/ {active=0}
         END {if (active || n != 2 || constants != 1) exit 1}' "$source" > "$inc/fragments.inc" || return 1
  fi
  if [[ "$1" == coalesce ]]; then
    awk '/^static INLINE (size_t get_left_size|void set_left_size)\(|^IRAM_ATTR inline static (bool is_tagged_as_free|header_t \*(left|right)_header)\(|^IRAM_ATTR void cmpct_free(_optionally_locked)?\(|^INLINE void cmpct_free_already_locked\(/ {active=1; n++}
         active {print}
         active && /^}/ {active=0}
         END {if (active || n != 8) exit 1}' "$source" > "$inc/coalesce.inc" || return 1
  fi
  if [[ "$1" == reclaim ]]; then
    awk '/^#define IS_PAGE_ALIGNED\(/ {print; defines++}
         /^static INLINE (size_t get_left_size|void set_left_size)\(|^IRAM_ATTR inline static header_t \*(left|right)_header\(|^IRAM_ATTR static (bool is_(start|end)_of_page_allocation|void (free_to_page_allocator|fix_left_size|unlink_free_unknown_bucket|free_memory))\(/ {active=1; n++}
         active {print}
         active && /^}/ {active=0}
         END {if (active || n != 10 || defines != 1) exit 1}' "$source" > "$inc/reclaim.inc" || return 1
  fi
  if [[ "$1" == split ]]; then
    awk '/^static INLINE (size_t get_left_size|void set_left_size)\(|^IRAM_ATTR inline static header_t \*right_header\(|^IRAM_ATTR static void fix_left_size\(|^IRAM_ATTR static void \*allocation_tail\(.*\)$/ {active=1; n++}
         active {print}
         active && /^}/ {active=0}
         END {if (active || n != 5) exit 1}' "$source" > "$inc/split.inc" || return 1
  fi
  if [[ "$1" == growth ]]; then
    awk '/^static const size_t arena_overhead =|^#define SMALL_ALLOCATION_LIMIT / {print; constants++}
         /^static inline size_t pages_for_bytes\(|^IRAM_ATTR static (int get_bucket_for_size|void add_to_heap|ssize_t heap_grow)\(|^IRAM_ATTR void \*(cmpct_alloc|cmpct_malloc_impl)\(/ {active=1; n++}
         active {print}
         active && /^}/ {active=0}
         END {if (active || n != 6 || constants != 2) exit 1}' "$source" > "$inc/growth.inc" || return 1
  fi
  if [[ "$1" == aligned ]]; then
    awk '/^static size_t aligned_prefix\(/ {active=1; n++}
         active {print}
         active && /^}/ {active=0}
         END {if (active || n != 1) exit 1}' "$source" > "$inc/aligned_prefix.inc" || return 1
    awk '/^static INLINE (size_t get_left_size|void set_left_size)\(|^IRAM_ATTR inline static header_t \*right_header\(|^IRAM_ATTR static void fix_left_size\(|^static inline size_t pages_for_bytes\(|^IRAM_ATTR void \*cmpct_aligned_alloc_impl\(/ {active=1; n++}
         active {print}
         active && /^}/ {active=0}
         END {if (active || n != 6) exit 1}' "$source" > "$inc/aligned.inc" || return 1
  fi
  ec618_cbmc "$name" "$inc" "ec618_$1" 5
}
spawn ec618_buckets buckets
spawn ec618_buckets reclaim
spawn ec618_buckets stats
spawn ec618_buckets stats_report
spawn ec618_buckets realloc_dispatch
spawn ec618_buckets allocation_size
spawn ec618_buckets fragments
spawn ec618_buckets coalesce
spawn ec618_buckets split
spawn ec618_buckets growth
spawn ec618_buckets aligned
ec618_page_operation() {
  local operation="$1" name="gc-ec618-page-$1" inc="$ACXX_WORK/gc-ec618-page-$1"
  [[ -n "$filter" && "$name/ILP32" != *"$filter"* ]] && return 0
  local source="$REPO_ROOT/toolchains/ec618/project/src/cmpctmalloc/cmpctmalloc.c"
  mkdir -p "$inc" || return 1
  ec618_arena_types "$source" "$inc" || return 1
  awk -v op="$operation" -v expected="$2" '/^typedef enum \{/ {body=$0; next}
       body {body=body "\n" $0}
       /^} page_use_t;/ && body {print body; n++}
       /^}/ {body=""}
       (op == "alloc" || op == "realloc") && /^static void fill_page_statuses\(/ {active=1; n++}
       op == "realloc" && /^static size_t (free_page_prefix|page_growth_start)\(/ {active=1; n++}
       op == "realloc" && /^IRAM_ATTR static size_t page_number\(/ {active=1; n++}
       (op == "realloc" || op == "realloc_commit") && (/^static inline size_t pages_for_bytes\(/ || /^IRAM_ATTR static void \*(page_grow_allocation|realloc_page_allocation)\(/) {active=1; n++}
       op == "alloc" && /^static size_t (free_page_prefix|first_free_page_run)\(/ {active=1; n++}
       (op == "alloc" || op == "alloc_commit") && /^IRAM_ATTR static void \*page_alloc\(/ {active=1; n++}
       op == "free" && /^IRAM_ATTR static (size_t page_number|bool is_page_allocated|void page_free)\(/ {active=1; n++}
       op == "free_commit" && /^IRAM_ATTR static (size_t page_number|void page_free)\(/ {active=1; n++}
       op == "free" && /^static size_t release_page_run\(/ {active=1; n++}
       op == "free" && /^IRAM_ATTR void cmpct_free_impl\(/ {active=1; n++}
       active {print}
       active && /^}/ {active=0}
       END {if (active || n != expected) exit 1}' "$source" > "$inc/page_$operation.inc" || return 1
  ec618_cbmc "$name" "$inc" "ec618_page_$operation" 6
}
spawn ec618_page_operation alloc 5
spawn ec618_page_operation alloc_commit 2
spawn ec618_page_operation free 6
spawn ec618_page_operation free_commit 3
spawn ec618_page_operation realloc 8
spawn ec618_page_operation realloc_commit 4
esp32_heap_aggregation() {
  local name=gc-esp32-heap-aggregation inc="$ACXX_WORK/gc-esp32-heap-aggregation"
  [[ -n "$filter" && "$name/ILP32" != *"$filter"* ]] && return 0
  local sdk="$REPO_ROOT/third_party/esp-idf/components/heap"
  mkdir -p "$inc" || return 1
  awk '/^#define SOC_MEMORY_TYPE_NO_PRIOS / {print; n++}
       END {if (n != 1) exit 1}' "$sdk/include/heap_memory_layout.h" > "$inc/sdk_heap.inc" || return 1
  awk '/^typedef struct heap_t_ \{/ {node=1; n++}
       node {print}
       /^} heap_t;/ {node=0}
       /^FORCE_INLINE_ATTR uint32_t get_all_caps\(|^bool heap_caps_match\(.*\)$/ || /^void heap_caps_get_info\(/ {active=1; n++}
       active {print}
       active && /^}/ {active=0}
       END {if (active || node || n != 4) exit 1}' "$sdk/heap_private.h" "$sdk/heap_caps.c" >> "$inc/sdk_heap.inc" || return 1
  cpp_equivalence "$name" ILP32 32 esp32_heap_aggregation "-I$inc" "-I$sdk/include" -DTOIT_FREERTOS --unwind 4
}
spawn esp32_heap_aggregation
esp32_heap_range() {
  local target="$1" mode="$2" name="gc-heap-range-$1-$2"
  local inc="$ACXX_WORK/$name" sdk="$REPO_ROOT/third_party/esp-idf/components"
  [[ -n "$filter" && "$name/ILP32" != *"$filter"* ]] && return 0
  mkdir -p "$inc" || return 1
  local flags=("-DCONFIG_IDF_TARGET_${target^^}=1")
  local external=0 revision=0 p4=0
  if [[ "$mode" != internal ]]; then
    external=1
    flags+=(-DCONFIG_TOIT_SPIRAM_HEAP)
    if [[ "$mode" == workaround ]]; then
      flags+=(-DCONFIG_SPIRAM_CACHE_WORKAROUND)
    elif [[ "$target" == esp32 ]]; then
      revision=1
    fi
  fi
  [[ "$target" == esp32p4 ]] && p4=1
  awk '/^#define MALLOC_CAP_(8BIT|DMA|SPIRAM|INTERNAL) / { print; n++ }
       /^#define SOC_DRAM_(LOW|HIGH) / { print; n++ }
       END { if (n != 6) exit 1 }' "$sdk/heap/include/esp_heap_caps.h" \
       "$sdk/soc/$target/include/soc/soc.h" > "$inc/range_constants.inc" || return 1
  awk '/^bool OS::use_spiram_for_(heap|metadata)_ =|^static const int (EXTERNAL_CAPS|INTERNAL_CAPS) =/ { print; constants++ }
       /^int OS::toit_heap_caps_flags_for_heap\(|^OS::HeapMemoryRange OS::get_heap_memory_range\(/ { active=1; n++ }
       active { print }
       active && /^}/ { active=0 }
       END { if (active || n != 2 || constants != 4) exit 1 }' "$REPO_ROOT/src/os_esp32.cc" > "$inc/heap_range.inc" || return 1
  cpp_equivalence "$name" ILP32 32 esp32_heap_range "-I$inc" "-I$sdk/heap/include" -DTOIT_FREERTOS \
    "${flags[@]}" "-DCXXV_ALLOW_EXTERNAL=$external" "-DCXXV_CHECK_REVISION=$revision" "-DCXXV_P4=$p4"
}
for target in esp32 esp32c3 esp32c6 esp32p4 esp32s2 esp32s3; do
  spawn esp32_heap_range "$target" internal
  spawn esp32_heap_range "$target" spiram
done
spawn esp32_heap_range esp32 workaround
spawn cpp_equivalence timer-delete LP64 64 timer_delete
spawn cpp_equivalence timer-delete ILP32 32 timer_delete
spawn cpp_equivalence timer-init LP64 64 timer_init
spawn cpp_equivalence timer-init ILP32 32 timer_init
spawn cpp_equivalence timer-create LP64 64 timer_create
spawn cpp_equivalence timer-create ILP32 32 timer_create
spawn cpp_equivalence encoder-buffer LP64 64 encoder_buffer --memory-leak-check
spawn cpp_equivalence encoder-buffer ILP32 32 encoder_buffer --memory-leak-check
spawn cpp_equivalence encoder-byte-array LP64 64 encoder_byte_array --unwind 41
spawn cpp_equivalence encoder-byte-array ILP32 32 encoder_byte_array --unwind 41
spawn cpp_equivalence encoder-numbers LP64 64 encoder_numbers --unwind 9 --fp2bv
spawn cpp_equivalence encoder-numbers ILP32 32 encoder_numbers --unwind 9 --fp2bv
spawn cpp_equivalence encoder-collections LP64 64 encoder_collections --unwind 11
spawn cpp_equivalence encoder-collections ILP32 32 encoder_collections --unwind 11
spawn cpp_equivalence visitor-dispatch LP64 64 visitor_dispatch
spawn cpp_equivalence visitor-dispatch ILP32 32 visitor_dispatch
spawn cpp_equivalence encoder-scalar LP64 64 encoder_scalar --fp2bv --unwind 9
spawn cpp_equivalence encoder-scalar ILP32 32 encoder_scalar --fp2bv --unwind 9
spawn cpp_equivalence encode-error-body LP64 64 encode_error -DRAW --memory-leak-check
spawn cpp_equivalence encode-error-body ILP32 32 encode_error -DRAW --memory-leak-check
spawn cpp_equivalence encoder-frames LP64 64 encoder_frames --unwind 9
spawn cpp_equivalence encoder-frames ILP32 32 encoder_frames --unwind 9
spawn cpp_equivalence encoder-frames-freertos ILP32 32 encoder_frames --unwind 9 -DCXXV_FREERTOS_TRACE
spawn cpp_equivalence v2-frame-walk LP64 64 v2_frame_walk
spawn cpp_equivalence v2-frame-walk ILP32 32 v2_frame_walk
spawn cpp_equivalence stack-records LP64 64 stack_records
spawn cpp_equivalence stack-records ILP32 32 stack_records
spawn cpp_equivalence task-stack-init LP64 64 task_stack_init
spawn cpp_equivalence task-stack-init ILP32 32 task_stack_init
spawn cpp_equivalence prepare-process-v2 LP64 64 prepare_process_v2
spawn cpp_equivalence prepare-process-v2 ILP32 32 prepare_process_v2
spawn cpp_equivalence initial-task-capacity LP64 64 initial_task_capacity
spawn cpp_equivalence initial-task-capacity ILP32 32 initial_task_capacity
spawn cpp_equivalence initial-task-capacity-freertos ILP32 32 initial_task_capacity -DTOIT_FREERTOS
instance_allocation() {
  local label="$1" abi="$2" bits="$3" harness="$4" name="$1/$2"
  shift 4
  [[ -n "$filter" && "$name" != *"$filter"* ]] && return 0
  local inc="$ACXX_WORK/$label-$bits"
  mkdir -p "$inc" || return 1
  awk '{ replaced += sub(/Utils::fill_words<Object\*>\(fields,/, "apply_field_fill(fields,"); print }
       END { if (replaced != 1) exit 1 }' "$REPO_ROOT/src/heap.cc" > "$inc/instance_heap.inc" || return 1
  if [[ "$harness" == allocate_task ]]; then
    # Retain the native constructor and bump/refusal decision. The fixture
    # asserts that neither slow-path provider is reached under pending GC.
    awk '/^OldSpace::OldSpace\(/ { ctor=1; ctors++ }
         /^uword OldSpace::allocate\(/ { alloc=1; allocs++ }
         ctor || alloc { print }
         ctor && /\{\}$/ { ctor=0 }
         alloc && /^}/ { alloc=0 }
         END { if (ctors != 1 || allocs != 1 || ctor || alloc) exit 1 }' \
      "$REPO_ROOT/src/third_party/dartino/object_memory_mark_sweep.cc" > "$inc/task_old_bump.inc" || return 1
  fi
  cpp_equivalence "$label" "$abi" "$bits" "$harness" "-I$inc" "$@"
}
spawn cpp_equivalence fresh-stack LP64 64 fresh_stack --unwind 10
spawn cpp_equivalence fresh-stack ILP32 32 fresh_stack --unwind 10
spawn instance_allocation instance-allocation LP64 64 instance_allocation
spawn instance_allocation instance-allocation ILP32 32 instance_allocation
spawn instance_allocation task-all-fields LP64 64 allocate_task -DCXXV_SYMBOLIC_FIELDS --unwind 10
spawn instance_allocation task-all-fields ILP32 32 allocate_task -DCXXV_SYMBOLIC_FIELDS --unwind 10
spawn instance_allocation task-retry-fields LP64 64 allocate_task -DCXXV_SYMBOLIC_FIELDS -DCXXV_TASK_RETRY --unwind 10
spawn instance_allocation task-retry-fields ILP32 32 allocate_task -DCXXV_SYMBOLIC_FIELDS -DCXXV_TASK_RETRY --unwind 10
spawn instance_allocation allocate-task LP64 64 allocate_task --unwind 10
spawn instance_allocation allocate-task ILP32 32 allocate_task --unwind 10
spawn cpp_equivalence task-start LP64 64 task_start
spawn cpp_equivalence task-start ILP32 32 task_start
spawn cpp_equivalence task-transfer LP64 64 task_transfer -DRAW
spawn cpp_equivalence task-transfer ILP32 32 task_transfer -DRAW
spawn cpp_equivalence mailbox-room LP64 64 mailbox_room
spawn cpp_equivalence mailbox-room ILP32 32 mailbox_room
spawn cpp_equivalence mailbox-delivery LP64 64 mailbox_delivery --unwind 4
spawn cpp_equivalence mailbox-delivery ILP32 32 mailbox_delivery --unwind 4
spawn cpp_equivalence mailbox-removal LP64 64 mailbox_removal
spawn cpp_equivalence mailbox-removal ILP32 32 mailbox_removal
encoder_handoff() {
  local label="$1" harness="$2" abi="$3" bits="$4" name="$1/$3"
  [[ -n "$filter" && "$name" != *"$filter"* ]] && return 0
  local inc="$ACXX_WORK/$label-$bits"
  mkdir -p "$inc" || return 1
  awk '/^uint8\* ByteArray::neuter\(/ { active=1; found++ }
       active { print }
       active && /^}$/ { active=0 }
       END { if (found != 1 || active) exit 1 }' "$REPO_ROOT/src/objects_runtime.cc" > "$inc/byte_array_neuter.inc" || return 1
  if [[ "$harness" == ipc_transferred_array ]]; then
    # Reaching the container branch fails this leaf proof. The guard must
    # itself be proved unreachable before the recursion can be excluded.
    awk '/^void MessageDecoder::deallocate\(\)/ { walk=1 }
         walk && /case TAG_MAP: \{/ {
           print; print "      CXXV_ASSERT(false, \"a transferred byte array never takes the container cleanup branch\"); return;"; inserted++; next
         }
         walk && /^}$/ { walk=0 }
         { print }
         END { if (inserted != 1) exit 1 }' "$REPO_ROOT/src/messaging.cc" > "$inc/ipc_external_messaging.inc" || return 1
  elif [[ "$harness" == encoder_handoff ]]; then
    # The concrete flag operation is checked by byte-array-neuter. Observe
    # the exact receiver and order at this call site in the table proof.
    awk '/^uint8\* MessageEncoder::take_buffer\(/ { taking=1 }
         taking && /array->clear_has_active_finalizer\(\);/ { sub(/array->clear_has_active_finalizer\(\);/, "observe_finalizer_clear(array);"); calls++ }
         taking && /^}$/ { taking=0 }
         { print }
         END { if (calls != 1) exit 1 }' "$REPO_ROOT/src/messaging.cc" > "$inc/encoder_tables.inc" || return 1
  fi
  shift 4
  cpp_equivalence "$label" "$abi" "$bits" "$harness" "-I$inc" "$@"
}
spawn encoder_handoff encoder-handoff encoder_handoff LP64 64 --unwind 10
spawn encoder_handoff encoder-handoff encoder_handoff ILP32 32 --unwind 10
spawn encoder_handoff byte-array-neuter byte_array_neuter LP64 64
spawn encoder_handoff byte-array-neuter byte_array_neuter ILP32 32
# One transfer, no copies, a length of at most five cardinal bytes, and
# a pointer copy of at most eight bytes. Unwinding assertions remain on.
ipc_array_bounds=(--unwind 2 --unwindsetname __memcpy_impl:0:9,N@toit@S@MessageEncoder@write_cardinal:0:5,N@toit@S@MessageDecoder@read_cardinal_64:0:5)
spawn encoder_handoff ipc-transferred-array ipc_transferred_array LP64 64 "${ipc_array_bounds[@]}"
spawn encoder_handoff ipc-transferred-array ipc_transferred_array ILP32 32 "${ipc_array_bounds[@]}"
ipc_byte_array_visit() {
  local abi="$1" bits="$2" name="ipc-byte-array-visit/$1"
  [[ -n "$filter" && "$name" != *"$filter"* ]] && return 0
  local inc="$ACXX_WORK/ipc-byte-array-visit-$bits"
  mkdir -p "$inc" || return 1
  awk '/^bool MessageEncoder::encode_(copy|byte_array)\(/ { active=1 }
       active && /write_uint8\(/ { sub(/write_uint8\(/, "visit_tag(this, "); tags++ }
       active && /write_cardinal\(/ { sub(/write_cardinal\(/, "visit_cardinal(this, "); lengths++ }
       active && /write_pointer\(/ { sub(/write_pointer\(/, "visit_pointer(this, "); ptrs++ }
       active && /data = malloc\(/ { sub(/malloc\(/, "allocate_copy("); allocations++ }
       active && /memcpy\(/ { sub(/memcpy\(/, "copy_payload("); copies++ }
       active && /^}$/ { active=0 }
       { print }
       END { if (allocations != 1 || copies != 2 || tags != 3 || lengths != 3 || ptrs != 2) exit 1 }' "$REPO_ROOT/src/messaging.cc" > "$inc/ipc_byte_array_visit.inc" || return 1
  cpp_equivalence ipc-byte-array-visit "$abi" "$bits" ipc_byte_array_visit "-I$inc" --unwind 9
}
spawn cpp_equivalence ipc-array-fields LP64 64 ipc_array_fields --unwind 9 --unwindsetname N@toit@S@MessageEncoder@write_cardinal:0:5,N@toit@S@MessageDecoder@read_cardinal_64:0:5
spawn cpp_equivalence ipc-array-fields ILP32 32 ipc_array_fields --unwind 9 --unwindsetname N@toit@S@MessageEncoder@write_cardinal:0:5,N@toit@S@MessageDecoder@read_cardinal_64:0:5
spawn ipc_byte_array_visit LP64 64
spawn ipc_byte_array_visit ILP32 32
ipc_scalar_leaf() {
  local suite="$1" harness="$2" abi="$3" bits="$4" name="$1/$3"
  [[ -n "$filter" && "$name" != *"$filter"* ]] && return 0
  local inc="$ACXX_WORK/$suite-$bits"
  mkdir -p "$inc" || return 1
  # Assert that the scalar leaf
  # never enters a compound value or blob path, including during disposal.
  awk '/^bool MessageEncoder::encode_(array|list_slice|list|map|byte_array|copy)\(/ { print; print "  CXXV_ASSERT(false, \"scalar encoding never enters a compound value\"); return false;"; enc++; next }
       /^Object\* MessageDecoder::decode_(array|map|string|byte_array)\(/ { print; print "  CXXV_ASSERT(false, \"scalar decoding never enters a compound value\"); return nullptr;"; dec++; next }
       /^void MessageDecoder::deallocate\(\)/ { walk=1 }
       walk && /case TAG_MAP: \{/ { print; print "      CXXV_ASSERT(false, \"scalar disposal never enters a compound value\"); return;"; cuts++; next }
       walk && /^}$/ { walk=0 }
       { print }
       END { if (enc != 6 || dec != 4 || cuts != 1) exit 1 }' "$REPO_ROOT/src/messaging.cc" > "$inc/ipc_scalar_messaging.inc" || return 1
  local cardinal_iterations=2
  [[ "$suite" == ipc-smi ]] && cardinal_iterations=10
  cpp_equivalence "$suite" "$abi" "$bits" "$harness" "-I$inc" --unwind 2 \
      --unwindsetname "__memcpy_impl:0:9,N@toit@S@MessageEncoder@write_cardinal:0:$cardinal_iterations,N@toit@S@MessageDecoder@read_cardinal_64:0:$cardinal_iterations"
}
spawn cpp_equivalence ipc-cardinal-wire LP64 64 ipc_cardinal --unwind 10
spawn cpp_equivalence ipc-cardinal-wire ILP32 32 ipc_cardinal --unwind 5
spawn ipc_scalar_leaf ipc-smi ipc_smi LP64 64
spawn ipc_scalar_leaf ipc-smi ipc_smi ILP32 32
spawn ipc_scalar_leaf ipc-fixed-scalar ipc_fixed_scalar LP64 64
spawn ipc_scalar_leaf ipc-fixed-scalar ipc_fixed_scalar ILP32 32
process_send_body() {
  local abi="$1" bits="$2" name="process-send-body/$1"
  [[ -n "$filter" && "$name" != *"$filter"* ]] && return 0
  local inc="$ACXX_WORK/process-send-body-$bits"
  mkdir -p "$inc" || return 1
  awk '/^PRIMITIVE\(process_send\) \{/ { active=1; found++ }
       active { print }
       active && /^}$/ { active=0 }
       END { if (found != 1 || active) exit 1 }' "$REPO_ROOT/src/primitive_core.cc" > "$inc/process_send.inc" || return 1
  awk '/^MessageEncoder::MessageEncoder\(Process\*/ || /^SystemMessage::SystemMessage\(.*MessageEncoder\*/ { active=1; found++ }
       active { print }
       active && /}[[:space:]]*$/ { active=0 }
       END { if (found != 2 || active) exit 1 }' "$REPO_ROOT/src/messaging.cc" > "$inc/process_send_constructors.inc" || return 1
  cpp_equivalence process-send-body "$abi" "$bits" process_send "-I$inc"
}
spawn process_send_body LP64 64
spawn process_send_body ILP32 32
# Check the production routing bodies with observers for lookup, wakeup and
# shutdown. Each C++ delete of the incoming message invokes the
# ownership observer (ESBMC cannot dispatch its virtual destructor).
# The other definitions in scheduler.cc implement those
# same operations, so including the entire translation unit would clash.
event_monitor_lifetime() {
  local abi="$1" bits="$2" inc="$ACXX_WORK/event-monitor-lifetime-$2"
  [[ -n "$filter" && "event-monitor-lifetime/$abi" != *"$filter"* ]] && return 0
  mkdir -p "$inc" || return 1
  awk '/^bool EventSource::update_resource_monitor\(/ { active=1; reg++ }
       /^void EventSource::delete_resource_monitor\(/ { active=1; unreg++ }
       /^ObjectNotifier::ObjectNotifier\(/ { active=1; ctor++ }
       /^ObjectNotifier::~ObjectNotifier\(/ { active=1; dtor++ }
       /^void ObjectNotifier::roots_do\(/ { active=1; slot++ }
       /^PRIMITIVE\(task_receive_message\)/ { active=1; receive++ }
       active { root_alloc += sub(/_new ObjectNotifier\(process, monitor\)/, "allocate_root(process, monitor)");
                msg_alloc += sub(/_new ObjectNotifyMessage\(notifier\)/, "allocate_message(notifier)");
                release += sub(/delete notifier;/, "destroy_root(notifier);"); print }
       active && /^}$/ { active=0 }
       END { if (slot != 1 || receive != 1 || release != 2 || root_alloc != 1 || msg_alloc != 1 || reg != 1 || unreg != 1 || ctor != 1 || dtor != 1 || active) exit 1 }' \
       "$REPO_ROOT/src/resource.cc" "$REPO_ROOT/src/heap.cc" "$REPO_ROOT/src/primitive_core.cc" > "$inc/monitor_lifetime.inc" || return 1
  cpp_equivalence event-monitor-lifetime "$abi" "$bits" event_monitor_lifetime "-I$inc" --unwind 3 --memory-leak-check
}
spawn event_monitor_lifetime LP64 64
spawn event_monitor_lifetime ILP32 32
monitor_scavenge() {
  local abi="$1" bits="$2" mode="$3" name="monitor-scavenge-${3,,}" inc="$ACXX_WORK/monitor-scavenge-${3,,}-$2"
  [[ -n "$filter" && "$name/$abi" != *"$filter"* ]] && return 0
  mkdir -p "$inc" || return 1
  awk '/^void ObjectNotifier::roots_do\(/ { active=1; slot++ }
       /^word HeapObject::size\(/ { active=1; size++ }
       active { print }
       active && /^}$/ { active=0 }
       END { if (slot != 1 || size != 1 || active) exit 1 }' "$REPO_ROOT/src/heap.cc" "$REPO_ROOT/src/objects.cc" > "$inc/monitor_root.inc" || return 1
  cpp_equivalence "$name" "$abi" "$bits" monitor_scavenge "-I$inc" "-DCXXV_MONITOR_MODE=$mode" --unwind 3 --unwindsetname __memcpy_impl:0:17 --boolector
}
for mode in YOUNG PROMOTED PROMOTION_FAILED; do
  spawn monitor_scavenge LP64 64 "$mode"
  spawn monitor_scavenge ILP32 32 "$mode"
done
scheduler_notify() {
  local abi="$1" bits="$2" inc="$ACXX_WORK/scheduler-notify-$2"
  [[ -n "$filter" && "scheduler-notify/$abi" != *"$filter"* ]] && return 0
  mkdir -p "$inc" || return 1
  awk '/^void Scheduler::send_notify_message\(/ { active=1; notify++ }
       /^void Scheduler::process_ready\(Locker&/ { active=1; ready++ }
       active { print }
       active && /^}$/ { active=0 }
       END { if (notify != 1 || ready != 1 || active) exit 1 }' "$REPO_ROOT/src/scheduler.cc" > "$inc/scheduler_notify.inc" || return 1
  cpp_equivalence scheduler-notify "$abi" "$bits" scheduler_notify "-I$inc" --unwind 3
}
spawn scheduler_notify LP64 64
spawn scheduler_notify ILP32 32
scheduler_delivery() {
  local abi="$1" bits="$2" name="scheduler-delivery/$1"
  [[ -n "$filter" && "$name" != *"$filter"* ]] && return 0
  local inc="$ACXX_WORK/scheduler-delivery-$bits"
  mkdir -p "$inc" || return 1
  awk '/^message_err_t Scheduler::send_message_from\(/ { active=1; direct++ }
       /^message_err_t Scheduler::send_system_message\(Locker&/ { active=1; system_route++ }
       active { gsub(/delete message;/, "cxxv_destroy(message);"); print }
       active && /^}$/ { active=0 }
       END { if (direct != 1 || system_route != 1 || active) exit 1 }' "$REPO_ROOT/src/scheduler.cc" > "$inc/send_message_from.inc" || return 1
  cpp_equivalence scheduler-delivery "$abi" "$bits" scheduler_delivery "-I$inc" --unwind 4
}
scheduler_gc_scan() {
  local abi="$1" bits="$2" name="scheduler-gc-scan/$1"
  [[ -n "$filter" && "$name" != *"$filter"* ]] && return 0
  local inc="$ACXX_WORK/scheduler-gc-scan-$bits"
  mkdir -p "$inc" || return 1
  awk '/^void Scheduler::gc\(/ { active=1; gc++ }
       /^void Scheduler::acknowledge_gc_preemption\(/ { active=1; ack++ }
       /^int Scheduler::request_gc_preemption\(/ { active=1; request++ }
       /^void Scheduler::select_gc_targets\(/ { active=1; select_count++ }
       /^void Scheduler::scan_gc_target\(/ { active=1; one++ }
       /^size_t Scheduler::scan_gc_targets\(/ { active=1; scan++ }
       /^void Scheduler::resume_gc_targets\(/ { active=1; drain++ }
       /^bool Scheduler::claim_gc_target\(/ { active=1; claim++ }
       /^void Scheduler::gc_suspend_process\(/ { active=1; suspend++ }
       /^void Scheduler::gc_resume_process\(/ { active=1; resume++ }
       /^void Scheduler::process_ready\(Locker&/ { active=1; ready++ }
       active { buckets += gsub(/ready_queue\(/, "selected_ready_queue("); print }
       active && /^}$/ { active=0 }
       END { if (gc != 1 || request != 1 || ack != 1 || select_count != 1 || one != 1 || scan != 1 || drain != 1 || claim != 1 || suspend != 1 || resume != 1 || ready != 1 || buckets != 2 || active) exit 1 }' "$REPO_ROOT/src/scheduler.cc" > "$inc/scheduler_gc_scan.inc" || return 1
  cpp_equivalence scheduler-gc-scan "$abi" "$bits" scheduler_gc_scan "-I$inc" --unwind 2
}
scheduler_worker_handoff() {
  local abi="$1" bits="$2" name="scheduler-worker-handoff/$1"
  [[ -n "$filter" && "$name" != *"$filter"* ]] && return 0
  local inc="$ACXX_WORK/scheduler-worker-handoff-$bits"
  mkdir -p "$inc" || return 1
  awk '/^void Scheduler::run\(SchedulerThread\*/ { active=1; loop++ }
       /^Process\* Scheduler::dequeue_ready_process\(/ { active=1; dequeue++ }
       /^void Scheduler::run_process\(/ { active=1; run++ }
       /^void Scheduler::wait_for_any_gc_to_complete\(/ { active=1; barrier++ }
       /^void Scheduler::acknowledge_gc_preemption\(/ { active=1; ack++ }
       /^int Scheduler::request_gc_preemption\(/ { active=1; request++ }
       /^void Scheduler::gc\(/ { active=1; gc++ }
       /^void Scheduler::select_gc_targets\(/ { active=1; select_count++ }
       /^void Scheduler::scan_gc_target\(/ { active=1; one++ }
       /^size_t Scheduler::scan_gc_targets\(/ { active=1; scan++ }
       /^void Scheduler::resume_gc_targets\(/ { active=1; drain++ }
       /^bool Scheduler::claim_gc_target\(/ { active=1; claim++ }
       /^void Interpreter::activate\(/ { active=1; bind++ }
       /^void Interpreter::deactivate\(/ { active=1; unbind++ }
       active { header_read += sub(/interpreter->preemption_method_header_bcp\(\)/, "read_preemption_header(interpreter)");
                completed += sub(/run_process\(locker, process, scheduler_thread\);/, "run_process(locker, process, scheduler_thread); handoff_finished();"); print }
       active && /^}$/ { active=0 }
       END { if (gc != 1 || select_count != 1 || one != 1 || scan != 1 || drain != 1 || claim != 1 || loop != 1 || dequeue != 1 || header_read != 1 || completed != 1 || run != 1 || barrier != 1 || request != 1 || ack != 1 || bind != 1 || unbind != 1 || active) exit 1 }' \
      "$REPO_ROOT/src/scheduler.cc" "$REPO_ROOT/src/interpreter.cc" > "$inc/scheduler_worker_handoff.inc" || return 1
  cpp_equivalence scheduler-worker-handoff "$abi" "$bits" scheduler_worker_handoff "-I$inc" --unwind 2 \
      --unwindsetname N@toit@S@Scheduler@request_gc_preemption:0:3,N@toit@S@Scheduler@run_process:0:3
}
scheduler_gc_ownership() {
  local abi="$1" bits="$2" name="scheduler-gc-ownership/$1"
  [[ -n "$filter" && "$name" != *"$filter"* ]] && return 0
  local inc="$ACXX_WORK/scheduler-gc-ownership-$bits"
  mkdir -p "$inc" || return 1
  awk '/^void Scheduler::update_priority\(/ { active=1; priority++ }
       /^bool Scheduler::claim_gc_target\(/ { active=1; claim++ }
       /^void Scheduler::gc_suspend_process\(/ { active=1; suspend++ }
       /^void Scheduler::gc_resume_process\(/ { active=1; resume++ }
       /^void Scheduler::resume_gc_targets\(/ { active=1; drain++ }
       /^void Scheduler::process_ready\(Locker&/ { active=1; ready++ }
       active { buckets += gsub(/ready_queue\(/, "selected_ready_queue("); print }
       active && /^}$/ { active=0 }
       END { if (priority != 1 || claim != 1 || suspend != 1 || resume != 1 || drain != 1 || ready != 1 || buckets != 3 || active) exit 1 }' "$REPO_ROOT/src/scheduler.cc" > "$inc/scheduler_gc_ownership.inc" || return 1
  cpp_equivalence scheduler-gc-ownership "$abi" "$bits" scheduler_gc_ownership "-I$inc" --unwind 3
}
scheduler_gc_barrier() {
  local abi="$1" bits="$2" name="scheduler-gc-barrier/$1"
  [[ -n "$filter" && "$name" != *"$filter"* ]] && return 0
  local inc="$ACXX_WORK/scheduler-gc-barrier-$bits"
  mkdir -p "$inc" || return 1
  awk '/^bool Scheduler::claim_gc_target\(/ { active=1; claim++ }
       /^void Scheduler::gc_suspend_process\(/ { active=1; suspend++ }
       /^void Scheduler::wait_for_any_gc_to_complete\(/ { active=1; barrier++ }
       active { buckets += gsub(/ready_queue\(/, "selected_ready_queue("); print }
       active && /^}$/ { active=0 }
       END { if (claim != 1 || suspend != 1 || barrier != 1 || buckets != 1 || active) exit 1 }' "$REPO_ROOT/src/scheduler.cc" > "$inc/scheduler_gc_barrier.inc" || return 1
  cpp_equivalence scheduler-gc-barrier "$abi" "$bits" scheduler_gc_barrier "-I$inc" --unwind 4
}
scheduler_teardown() {
  local abi="$1" bits="$2" name="scheduler-teardown/$1"
  [[ -n "$filter" && "$name" != *"$filter"* ]] && return 0
  local inc="$ACXX_WORK/scheduler-teardown-$bits"
  mkdir -p "$inc" || return 1
  awk '/^void Scheduler::terminate_process\(/ { active=1; found++ }
       /^void Scheduler::wait_for_any_gc_to_complete\(/ { active=1; barrier++ }
       active { sub(/delete process;/,"observe_destroy(process);");
                sub(/delete message;/,"observe_destroy(message);"); sub(/delete group;/,"observe_destroy(group);"); print }
       active && /^}$/ { active=0 }
       END { if (found != 1 || barrier != 1 || active) exit 1 }' "$REPO_ROOT/src/scheduler.cc" > "$inc/terminate_process.inc" || return 1
  cpp_equivalence scheduler-teardown "$abi" "$bits" scheduler_teardown "-I$inc" --unwind 4
}
scheduler_spawn() {
  local abi="$1" bits="$2" name="scheduler-spawn/$1"
  [[ -n "$filter" && "$name" != *"$filter"* ]] && return 0
  local inc="$ACXX_WORK/scheduler-spawn-$bits"
  mkdir -p "$inc" || return 1
  awk '/^int Scheduler::spawn\(/ { active=1; found++ }
       active { allocations += sub(/_new Process\(/,"construct_process(");
                sub(/delete termination;/,"destroy_notice(termination);");
                sub(/delete spawned;/,"destroy_notice(spawned);"); print }
       active && /^}$/ { active=0 }
       END { if (found != 1 || allocations != 1 || active) exit 1 }' "$REPO_ROOT/src/scheduler.cc" > "$inc/scheduler_spawn.inc" || return 1
  cpp_equivalence scheduler-spawn "$abi" "$bits" scheduler_spawn "-I$inc" --unwind 9
}
spawn scheduler_spawn LP64 64
spawn scheduler_worker_handoff LP64 64
spawn scheduler_worker_handoff ILP32 32
spawn scheduler_gc_ownership LP64 64
spawn scheduler_gc_ownership ILP32 32
spawn scheduler_gc_barrier LP64 64
spawn scheduler_gc_barrier ILP32 32
spawn cpp_equivalence scheduler-target-queue LP64 64 scheduler_target_queue --unwind 2
spawn cpp_equivalence scheduler-target-queue ILP32 32 scheduler_target_queue --unwind 2
spawn scheduler_gc_scan LP64 64
spawn scheduler_gc_scan ILP32 32
spawn scheduler_spawn ILP32 32
spawn scheduler_teardown LP64 64
spawn scheduler_teardown ILP32 32
spawn scheduler_delivery LP64 64
spawn scheduler_delivery ILP32 32
spawn cpp_equivalence task-id-exhaustion LP64 64 task_id_exhaustion --unwind 2
spawn cpp_equivalence task-id-exhaustion ILP32 32 task_id_exhaustion --unwind 2
spawn cpp_equivalence task-new LP64 64 task_new -DRAW
spawn cpp_equivalence task-new ILP32 32 task_new -DRAW
for target in LP64 ILP32; do
  if [[ "v2-table-loop/$target" == *"$filter"* ]]; then spawn ./loader/wp.sh "$target"; fi
  if [[ "gc-page-scan-wp/$target" == *"$filter"* ]]; then spawn ./heap/page-scan-wp.sh "$target"; fi
done
spawn cpp_equivalence smi-cpp LP64 64 smi
spawn cpp_equivalence smi-cpp ILP32 32 smi
spawn cpp_equivalence error-roots-cpp LP64 64 error_roots
spawn cpp_equivalence error-roots-cpp ILP32 32 error_roots
spawn cpp_equivalence program-heap-native LP64 64 program_heap
spawn cpp_equivalence program-heap-native ILP32 32 program_heap
spawn cpp_equivalence program-class-ids-native LP64 64 program_class_ids
spawn cpp_equivalence program-class-ids-native ILP32 32 program_class_ids
spawn cpp_equivalence blit-pixel LP64 64 blit_pixel
spawn cpp_equivalence blit-pixel ILP32 32 blit_pixel
spawn cpp_equivalence chunk-iterator LP64 64 chunk_iterator
spawn cpp_equivalence chunk-iterator ILP32 32 chunk_iterator
old_chunk_expansion() {
  local abi="$1" bits="$2" name="old-chunk-expansion/$1"
  [[ -n "$filter" && "$name" != *"$filter"* ]] && return 0
  local inc="$ACXX_WORK/old-chunk-expansion-$bits"
  mkdir -p "$inc" || return 1
  # Keep the quota path native. Substitute the verified installer and bump
  # allocator so admission can range over every representable page count.
  awk '/^OldSpace::OldSpace\(/ { ctor=1; found++ }
       ctor { print; if (/\{\}$/) ctor=0; next }
       /^static uword promotion_chunk_size\(|^uword OldSpace::allocate_in_new_chunk\(/ { active=1; found++ }
       active { print }
       active && /^}$/ { active=0 }
       /^uword OldSpace::used\(\) const \{.*}$/ { print; found++ }
       END { if (found != 4 || active || ctor) exit 1 }' \
    "${CXXV_SRC:-$REPO_ROOT/src}/third_party/dartino/object_memory_mark_sweep.cc" > "$inc/old_chunk_expansion.inc" || return 1
  cpp_equivalence old-chunk-expansion "$abi" "$bits" old_chunk_expansion "-I$inc"
}
spawn old_chunk_expansion LP64 64
spawn old_chunk_expansion ILP32 32
spawn cpp_equivalence old-chunk-install LP64 64 old_chunk_install --unwind 3
spawn cpp_equivalence old-chunk-install ILP32 32 old_chunk_install --unwind 3
spawn cpp_equivalence gc-chunk-insert LP64 64 gc_chunk_insert --unwind 4
spawn cpp_equivalence gc-chunk-insert ILP32 32 gc_chunk_insert --unwind 4
gc_chunk_with_destructor() {
  local name="$1" abi="$2" bits="$3" harness="$4" inc="$ACXX_WORK/$1-$2"
  shift 4
  [[ -n "$filter" && "$name/$abi" != *"$filter"* ]] && return 0
  local dir="${CXXV_SRC:-$REPO_ROOT/src}/third_party/dartino"
  mkdir -p "$inc" || return 1
  # ESBMC drops the Chunk destructor at a delete expression. Spell out its
  # two operations for this non-null, exact-type descriptor.
  awk '/^  delete chunk;$/ {print "  chunk->~Chunk();"; print "  ::operator delete(chunk);"; n++; next}
       {print}
       END {if (n != 1) exit 1}' "$dir/object_memory.cc" > "$inc/object_memory.inc" || return 1
  cpp_equivalence "$name" "$abi" "$bits" "$harness" "-I$inc" "-I$dir" --memory-leak-check "$@"
}
spawn gc_chunk_with_destructor gc-chunk-lifecycle LP64 64 gc_chunk_lifecycle
spawn gc_chunk_with_destructor gc-chunk-lifecycle ILP32 32 gc_chunk_lifecycle
spawn gc_chunk_with_destructor gc-chunk-lifecycle-freertos ILP32 32 gc_chunk_lifecycle -DTOIT_FREERTOS --unwind 3
spawn gc_chunk_with_destructor gc-spare-selection ILP32 32 gc_spare_selection -DTOIT_FREERTOS --unwind 3
spawn cpp_equivalence gc-spare-lifecycle LP64 64 gc_spare_lifecycle --memory-leak-check
spawn cpp_equivalence gc-spare-lifecycle ILP32 32 gc_spare_lifecycle --memory-leak-check
spawn cpp_equivalence gc-spare-exchange LP64 64 gc_spare_exchange --unwind 3
spawn cpp_equivalence gc-spare-exchange ILP32 32 gc_spare_exchange --unwind 3
spawn cpp_equivalence gc-scavenge-start LP64 64 gc_scavenge_start --unwind 2
spawn cpp_equivalence gc-scavenge-start ILP32 32 gc_scavenge_start --unwind 2
spawn cpp_equivalence gc-scavenge-phases LP64 64 gc_scavenge_phases --unwind 4
spawn cpp_equivalence gc-scavenge-phases ILP32 32 gc_scavenge_phases --unwind 4
spawn cpp_equivalence gc-host-pages LP64 64 gc_host_pages --unwind 65
spawn cpp_equivalence gc-host-pages ILP32 32 gc_host_pages --unwind 65
sweep_chunk_limits=(--unwind 2 --unwindsetname object_memory_mark_sweep.cc@N@toit@S@OldSpace@sweep:2:3,sweep_empty_cards.h@N@toit@sweep_empty_cards:0:4,sweep_empty_cards.h@N@toit@fill_unmarked_words:0:33,N@toit@S@FreeList@clear:0:13,__memset_impl:0:13)
spawn cpp_equivalence gc-sweep-chunk LP64 64 gc_sweep_chunk "${sweep_chunk_limits[@]}"
spawn cpp_equivalence gc-sweep-chunk ILP32 32 gc_sweep_chunk "${sweep_chunk_limits[@]}"
spawn cpp_equivalence gc-sweep-free-region LP64 64 gc_sweep_free_region
spawn cpp_equivalence gc-sweep-free-region ILP32 32 gc_sweep_free_region
spawn cpp_equivalence gc-page-fragmentation LP64 64 gc_page_fragmentation --unwind 65
spawn cpp_equivalence gc-page-fragmentation ILP32 32 gc_page_fragmentation --unwind 65
spawn cpp_equivalence gc-page-update LP64 64 gc_page_update
spawn cpp_equivalence gc-page-update ILP32 32 gc_page_update
spawn cpp_equivalence gc-page-protection LP64 64 gc_page_protection
spawn cpp_equivalence gc-page-protection ILP32 32 gc_page_protection
spawn cpp_equivalence gc-page-reservation LP64 64 gc_page_reservation
spawn cpp_equivalence gc-page-reservation ILP32 32 gc_page_reservation
spawn cpp_equivalence gc-heap-reservation LP64 64 gc_heap_reservation
spawn cpp_equivalence gc-heap-reservation ILP32 32 gc_heap_reservation
spawn cpp_equivalence external-accounting LP64 64 external_accounting
spawn cpp_equivalence external-accounting ILP32 32 external_accounting
# The two-thread harness explores scheduling choices as well as symbolic sizes.
if [ "$QUICK" != 1 ]; then
  spawn cpp_equivalence external-accounting-threads LP64 64 external_accounting_threads
  spawn cpp_equivalence external-accounting-threads ILP32 32 external_accounting_threads
fi
spawn cpp_equivalence boxed-allocation LP64 64 boxed_allocation
spawn cpp_equivalence boxed-allocation ILP32 32 boxed_allocation
spawn cpp_equivalence gc-mark-all LP64 64 gc_mark_all
spawn cpp_equivalence gc-mark-all ILP32 32 gc_mark_all
spawn cpp_equivalence gc-mark-all-aligned LP64 64 gc_mark_all -DCXXV_ALIGNED_MARK
spawn cpp_equivalence gc-mark-all-aligned ILP32 32 gc_mark_all -DCXXV_ALIGNED_MARK
# Three-word copies exercise the ESBMC libc byte loop, including its exit.
spawn cpp_equivalence gc-scavenge-alias LP64 64 gc_scavenge_alias --unwind 25 --boolector
spawn cpp_equivalence gc-scavenge-alias ILP32 32 gc_scavenge_alias --unwind 25
spawn cpp_equivalence gc-scavenge-graph LP64 64 gc_scavenge_graph --unwind 3 --boolector
spawn cpp_equivalence gc-scavenge-graph ILP32 32 gc_scavenge_graph --unwind 3 --boolector
spawn cpp_equivalence gc-promotion-capacity LP64 64 gc_promotion_capacity
spawn cpp_equivalence gc-promotion-capacity ILP32 32 gc_promotion_capacity
spawn cpp_equivalence gc-promoted-track LP64 64 gc_promoted_track --unwind 4
spawn cpp_equivalence gc-promoted-track ILP32 32 gc_promoted_track --unwind 4
spawn cpp_equivalence gc-process-epoch LP64 64 gc_process_epoch
spawn cpp_equivalence gc-process-epoch ILP32 32 gc_process_epoch
for abi in LP64 ILP32; do
  bits=64
  [[ "$abi" == ILP32 ]] && bits=32
  spawn cpp_equivalence core-entry "$abi" "$bits" core_entry --unwind 3
  spawn cpp_equivalence core-entry-checked "$abi" "$bits" core_entry --unwind 3 -DTOIT_VERIFIED_CORE_CHECKED_LOOP
done
spawn cpp_equivalence gc-stack-barrier LP64 64 gc_stack_barrier
spawn cpp_equivalence gc-stack-barrier ILP32 32 gc_stack_barrier
gc_stack_scan_entry() {
  local abi="$1" bits="$2" name="gc-stack-scan-entry/$1"
  [[ -n "$filter" && "$name" != *"$filter"* ]] && return 0
  local inc="$ACXX_WORK/gc-stack-scan-entry-$bits"
  mkdir -p "$inc" || return 1
  awk '/^void Stack::roots_do\(Program\* program, RootCallback\* cb\) \{$/ { active=1; found++ }
       active { print }
       active && /^}$/ { active=0 }
       END { if (found != 1 || active) exit 1 }' \
    "${CXXV_SRC:-$REPO_ROOT/src}/objects.cc" > "$inc/stack_roots_do.inc" || return 1
  cpp_equivalence gc-stack-scan-entry "$abi" "$bits" gc_stack_scan_entry "-I$inc" --unwind 9
}
spawn cpp_equivalence snapshot-bytecode-slice LP64 64 snapshot_bytecode_slice --unwind 5
spawn cpp_equivalence snapshot-bytecode-slice ILP32 32 snapshot_bytecode_slice --unwind 5
spawn cpp_equivalence image-backing-debug LP64 64 image_backing -DCXXV_IMAGE_DEBUG
spawn cpp_equivalence image-backing-debug ILP32 32 image_backing -DCXXV_IMAGE_DEBUG
spawn cpp_equivalence process-group-lifetime LP64 64 process_group_lifetime --unwind 4
spawn cpp_equivalence process-group-lifetime ILP32 32 process_group_lifetime --unwind 4
spawn cpp_equivalence image-backing LP64 64 image_backing
spawn cpp_equivalence image-backing ILP32 32 image_backing
spawn cpp_equivalence snapshot-image-layout LP64 64 snapshot_image_layout
spawn cpp_equivalence snapshot-image-layout ILP32 32 snapshot_image_layout
spawn gc_stack_scan_entry LP64 64
spawn gc_stack_scan_entry ILP32 32
spawn cpp_equivalence gc-stack-shrink LP64 64 gc_stack_shrink --unwind 2
spawn cpp_equivalence gc-stack-shrink ILP32 32 gc_stack_shrink --unwind 2
spawn cpp_equivalence gc-root-iterator LP64 64 gc_root_iterator
spawn cpp_equivalence gc-root-iterator ILP32 32 gc_root_iterator
spawn cpp_equivalence gc-process-roots LP64 64 gc_process_roots --unwind 3
spawn cpp_equivalence gc-process-roots ILP32 32 gc_process_roots --unwind 3
spawn cpp_equivalence gc-current-task LP64 64 gc_current_task --unwind 3
spawn cpp_equivalence gc-current-task ILP32 32 gc_current_task --unwind 3
spawn cpp_equivalence gc-collection-phases LP64 64 gc_collection_phases --unwind 10
spawn cpp_equivalence gc-collection-phases ILP32 32 gc_collection_phases --unwind 10
spawn cpp_equivalence gc-overflow-registration LP64 64 gc_overflow_registration --unwind 9
spawn cpp_equivalence gc-overflow-registration ILP32 32 gc_overflow_registration --unwind 9
spawn cpp_equivalence gc-object-size LP64 64 gc_object_size --unwind 2
spawn cpp_equivalence gc-object-size ILP32 32 gc_object_size --unwind 2
spawn cpp_equivalence gc-object-roots LP64 64 gc_object_roots --unwind 2
spawn cpp_equivalence gc-object-roots ILP32 32 gc_object_roots --unwind 2
spawn cpp_equivalence gc-mark-range LP64 64 gc_mark_range
spawn cpp_equivalence gc-mark-range ILP32 32 gc_mark_range
spawn cpp_equivalence gc-overflow-byte LP64 64 gc_overflow_byte --unwind 9
spawn cpp_equivalence gc-overflow-byte ILP32 32 gc_overflow_byte --unwind 9
spawn cpp_equivalence gc-mark-queue LP64 64 gc_mark_queue
spawn cpp_equivalence gc-mark-queue ILP32 32 gc_mark_queue
spawn cpp_equivalence gc-page-type LP64 64 gc_page_type
spawn cpp_equivalence gc-page-type ILP32 32 gc_page_type
spawn cpp_equivalence gc-metadata-commit LP64 64 gc_metadata_commit
spawn cpp_equivalence gc-metadata-commit ILP32 32 gc_metadata_commit
spawn cpp_equivalence gc-metadata-layout LP64 64 gc_metadata_layout
spawn cpp_equivalence gc-metadata-layout ILP32 32 gc_metadata_layout
spawn cpp_equivalence gc-metadata-layout-ec618 ILP32 32 gc_metadata_layout --multi-property -DTOIT_FREERTOS
spawn cpp_equivalence gc-metadata-layout-esp32 ILP32 32 gc_metadata_layout --multi-property -DTOIT_FREERTOS -DCXXV_ESP32
spawn cpp_equivalence gc-remembered-card LP64 64 gc_remembered_card
spawn cpp_equivalence gc-remembered-card ILP32 32 gc_remembered_card
spawn cpp_equivalence gc-compacted-chunk-tails LP64 64 gc_compacted_chunk_tails --unwind 3
spawn cpp_equivalence gc-compacted-chunk-tails ILP32 32 gc_compacted_chunk_tails --unwind 3
spawn cpp_equivalence gc-compaction-destinations LP64 64 gc_compaction_destinations --unwind 3
spawn cpp_equivalence gc-compaction-destinations ILP32 32 gc_compaction_destinations --unwind 3
spawn cpp_equivalence gc-compaction-dead-visit LP64 64 gc_compaction_dead_visit --unwind 5
spawn cpp_equivalence gc-compaction-dead-visit ILP32 32 gc_compaction_dead_visit --unwind 5
spawn cpp_equivalence gc-compaction-live-visit LP64 64 gc_compaction_live_visit --unwind 4
spawn cpp_equivalence gc-compaction-live-visit ILP32 32 gc_compaction_live_visit --unwind 4
spawn cpp_equivalence gc-compaction-visit-switch LP64 64 gc_compaction_live_visit -DCXXV_SWITCH --unwind 4
spawn cpp_equivalence gc-compaction-visit-switch ILP32 32 gc_compaction_live_visit -DCXXV_SWITCH --unwind 4
spawn cpp_equivalence gc-compaction-fix-roots LP64 64 gc_compaction_fix_roots --unwind 33
spawn cpp_equivalence gc-compaction-fix-roots ILP32 32 gc_compaction_fix_roots --unwind 33
spawn cpp_equivalence gc-compaction-card-rank LP64 64 gc_compaction_card_rank
spawn cpp_equivalence gc-compaction-card-rank ILP32 32 gc_compaction_card_rank
spawn cpp_equivalence gc-compaction-sentinel LP64 64 gc_compaction_sentinel
spawn cpp_equivalence gc-compaction-sentinel ILP32 32 gc_compaction_sentinel
compaction_scan() {
  local abi="$1" bits="$2" inc="$ACXX_WORK/compaction-scan-$2"
  [[ -n "$filter" && "gc-compaction-scan/$abi" != *"$filter"* ]] && return 0
  mkdir -p "$inc" || return 1
  awk '/^GcMetadata::Destination GcMetadata::calculate_object_destinations[(]/ { planner=1 }
       planner && /^    while [(]dest.address <= dest.limit[)] [{]$/ { active=1; loops++ }
       active && /^        return dest;$/ { print "        reason = SOURCE_END;"; exits++ }
       active && /^    }$/ { print "      reason = ADVANCED; return dest;"; active=0; edges++; print; next }
       active { print }
       /^}/ { planner=0 }
       END { if (loops != 1 || exits != 1 || edges != 1 || active) exit 1 }' \
      "$REPO_ROOT/src/third_party/dartino/gc_metadata.cc" > "$inc/compaction_scan.inc" || return 1
  cpp_equivalence gc-compaction-scan "$abi" "$bits" gc_compaction_scan "-I$inc" --unwind 33
}
spawn compaction_scan LP64 64
spawn compaction_scan ILP32 32
compaction_switch() {
  local abi="$1" bits="$2" inc="$ACXX_WORK/compaction-switch-$2"
  [[ -n "$filter" && "gc-compaction-switch/$abi" != *"$filter"* ]] && return 0
  mkdir -p "$inc" || return 1
  awk '/^GcMetadata::Destination GcMetadata::calculate_object_destinations[(]/ { planner=1 }
       planner && /if [(]src == src_start[)] [{]/ { block++; active=1; next }
       active { print; if ($0 ~ /^[[:space:]]*goto restart;/) { active=0; jumps++ } }
       /^}/ { planner=0 }
       END { if (block != 1 || jumps != 1 || active) exit 1 }' \
      "$REPO_ROOT/src/third_party/dartino/gc_metadata.cc" > "$inc/compaction_switch.inc" || return 1
  awk '/^GcMetadata::Destination GcMetadata::calculate_object_destinations[(]/ { planner=1 }
       planner && /^    int overhang =/ { active=1; differences++ }
       active && /^    src_start = src;/ { active=0; ends++ }
       active { print }
       /^}/ { planner=0 }
       END { if (differences != 1 || ends != 1 || active) exit 1 }' \
      "$REPO_ROOT/src/third_party/dartino/gc_metadata.cc" > "$inc/compaction_overhang.inc" || return 1
  cpp_equivalence gc-compaction-switch "$abi" "$bits" gc_compaction_switch "-I$inc"
}
spawn compaction_switch LP64 64
spawn compaction_switch ILP32 32
# Three source cards, one retry at the same source line, and at most one
# object per backtracking walk. Unwinding assertions remain enabled.
metadata_class=N@toit@S@GcMetadata@
planner=${metadata_class}calculate_object_destinations
overhang_limits=(--unwind 4 --unwindsetname "$planner:1:2,$planner:3:2,${metadata_class}end_of_destination_of_last_live_object_starting_before:0:2,${metadata_class}last_line_that_fits:1:2")
spawn cpp_equivalence gc-compaction-overhang LP64 64 gc_compaction_overhang "${overhang_limits[@]}"
spawn cpp_equivalence gc-compaction-overhang ILP32 32 gc_compaction_overhang "${overhang_limits[@]}"
compaction_last_fit() {
  local abi="$1" bits="$2" inc="$ACXX_WORK/compaction-last-fit-$2"
  [[ -n "$filter" && "gc-compaction-last-fit/$abi" != *"$filter"* ]] && return 0
  mkdir -p "$inc" || return 1
  awk '/^uword GcMetadata::last_line_that_fits[(]/ { active=1; bodies++; sub(/GcMetadata::/, "CheckedPlanner::") }
       active {
         sizes += gsub(/object->size[(]program[)]/, "checked_size(object, program)")
         marks += gsub(/is_marked[(]object[)]/, "header_at(object->_raw())->marked")
         dests += gsub(/get_destination[(]object[)]/, "header_at(object->_raw())->destination")
         sentinels += gsub(/has_sentinel_at[(]object->_raw[(][)][)]/, "header_at(object->_raw())->sentinel")
         print
       }
       /^}/ { active=0 }
       END { if (bodies != 1 || sizes != 2 || marks != 1 || dests != 2 || sentinels != 3 || active) exit 1 }' \
      "$REPO_ROOT/src/third_party/dartino/gc_metadata.cc" > "$inc/compaction_last_fit.inc" || return 1
  cpp_equivalence gc-compaction-last-fit "$abi" "$bits" gc_compaction_last_fit "-I$inc" --reserve-first-page --unwind 5
}
spawn compaction_last_fit LP64 64
spawn compaction_last_fit ILP32 32
spawn cpp_equivalence gc-compaction-object-ends LP64 64 gc_compaction_object_ends --unwind 3
spawn cpp_equivalence gc-compaction-object-ends ILP32 32 gc_compaction_object_ends --unwind 3
spawn cpp_equivalence gc-metadata-access LP64 64 gc_metadata_access
spawn cpp_equivalence gc-metadata-access ILP32 32 gc_metadata_access
spawn cpp_equivalence gc-internal-ram-range ILP32 32 gc_internal_ram_range
spawn cpp_equivalence promotion-header LP64 64 promotion_header
spawn cpp_equivalence promotion-header ILP32 32 promotion_header
spawn cpp_equivalence free-list-bucket LP64 64 free_list_bucket --unwind 12
spawn cpp_equivalence free-list-bucket ILP32 32 free_list_bucket --unwind 12
spawn cpp_equivalence free-list-region LP64 64 free_list_region --unwind 4
spawn cpp_equivalence free-list-region ILP32 32 free_list_region --unwind 4
spawn cpp_equivalence free-list-selection LP64 64 free_list_selection --unwind 13
spawn cpp_equivalence free-list-selection ILP32 32 free_list_selection --unwind 13
spawn cpp_equivalence old-space-retry LP64 64 old_space_retry
spawn cpp_equivalence old-space-retry ILP32 32 old_space_retry
array_allocation() {
  local name="process-array-allocation/$1" bits="$2"
  [[ -n "$filter" && "$name" != *"$filter"* ]] && return 0
  source ../env.sh
  local modes=(proof) mode log
  (( QUICK )) || modes+=(young-filler old-filler unmarked-old)
  for mode in "${modes[@]}"; do
    log="$ACXX_WORK/logs/process-array-allocation-$bits-$mode.log"
    if python3 heap/check_array_allocation.py "$mode" "$bits" "$CXXV_SRC" "$ACXX_WORK" \
        ../harness/process_array_allocation.cc "$ESBMC" "${CXXV_FLAGS[@]}" -DTOIT_VERIFIED_CORE > "$log" 2>&1; then
      echo "ok    $name $mode"
    else
      echo "FAIL  $name $mode see $log"
      return 1
    fi
  done
}
spawn array_allocation LP64 64
spawn array_allocation ILP32 32
spawn cpp_equivalence internal-string-allocation LP64 64 internal_string_allocation
spawn cpp_equivalence internal-string-allocation ILP32 32 internal_string_allocation
spawn cpp_equivalence external-blob-allocation LP64 64 external_blob_allocation
spawn cpp_equivalence external-blob-allocation ILP32 32 external_blob_allocation
spawn cpp_equivalence process-blob-allocation LP64 64 process_blob_allocation --memory-leak-check
spawn cpp_equivalence process-blob-allocation ILP32 32 process_blob_allocation --memory-leak-check
spawn cpp_equivalence byte-array-initialization LP64 64 byte_array_initialization
spawn cpp_equivalence byte-array-initialization ILP32 32 byte_array_initialization
entry encoder               pass "" encoder/message_encoder.gen.c
# The bound of write_cardinal's bytes (encoder/cardinal.h), with Z3.
entry ipc-tree-disposal       pass "" decoder/ipc_disposal.gen.c -allow_dead_code -prover z3v4.5
mutant ipc-tree-disposal-written-digit decoder/ipc_disposal.render src/messaging.cc 'tag_at|Cannot prove|u_character' "-allow_dead_code -prover z3v4.5" \
    'write_uint8((uint8) (value % 128 + 128));' 'write_uint8((uint8) (value % 128));'
mutant ipc-tree-disposal-smi-sign decoder/ipc_disposal.render src/messaging.cc 'Cannot prove|u_character' "-allow_dead_code -prover z3v4.5" \
    'write_uint8(TAG_NEGATIVE_SMI);' 'write_uint8(TAG_POSITIVE_SMI);'
mutant ipc-tree-disposal-array-child decoder/ipc_disposal.render src/messaging.cc 'node|Cannot prove|No matching' "-allow_dead_code -prover z3v4.5" \
    'if (!encode_any(object->at(i))) return false;' 'if (!encode_any(object->at(i))) return true;'
mutant ipc-tree-disposal-array-count decoder/ipc_disposal.render src/messaging.cc 'cardinal_at|Cannot prove' "-allow_dead_code -prover z3v4.5" \
    'write_cardinal(to - from);' 'write_cardinal(from == to ? static_cast<word>(1) : to - from);'
mutant ipc-tree-disposal-map decoder/ipc_disposal.render src/messaging.cc 'forest|end|length' "-allow_dead_code -prover z3v4.5" \
    'if (tag == TAG_MAP) length *= 2;' 'if (tag == TAG_MAP) length *= 1;'
mutant ipc-tree-disposal-owner decoder/ipc_disposal.render src/messaging.cc 'leak|malloc_block' "-allow_dead_code -prover z3v4.5" \
    'free(read_pointer());' 'read_pointer();'
mutant ipc-tree-disposal-digit decoder/ipc_disposal.render src/messaging.cc 'value|result' "-allow_dead_code -prover z3v4.5" \
    'result += static_cast<uint64>(byte) << shift;' 'result += static_cast<uint64>(byte);'
entry ipc-map-traversal       pass "" encoder/ipc_map.gen.c
mutant ipc-map-traversal-value encoder/ipc_map.render src/messaging.cc 'map_prefix|failed_pair' "" \
    'Object* value = array->at(i + 1);' 'Object* value = array->at(i);'
mutant ipc-map-traversal-tombstone encoder/ipc_map.render src/messaging.cc 'map_prefix|failed_pair' "" \
    'if (is_smi(key) || HeapObject::cast(key)->class_id() != program_->tombstone_class_id())' 'if (true)'
mutant ipc-map-traversal-short encoder/ipc_map.render src/messaging.cc 'length|size|count' "" \
    'return count == size;' 'return true;'
entry ipc-array-traversal     pass "" encoder/ipc_array.gen.c
mutant ipc-array-traversal-list-range encoder/ipc_array.render src/messaging.cc 'readable_slice|trace|Cannot prove' "" \
    'if (!is_smi(size) || to > Smi::value(size)) return false;' 'if (!is_smi(size)) return false;'
mutant ipc-array-traversal-list-start encoder/ipc_array.render src/messaging.cc 'trace|Cannot prove' "" \
    'return encode_array(array, from, to);' 'return encode_array(array, 0, to);'
mutant ipc-array-traversal-slice-start encoder/ipc_array.render src/messaging.cc 'trace|Cannot prove' "" \
    'return encode_list(backing, from, to);' 'return encode_list(backing, 0, to);'
mutant ipc-array-traversal-repeat encoder/ipc_array.render src/messaging.cc 'nth' "" \
    'if (!encode_any(object->at(i))) return false;' 'if (!encode_any(object->at(from))) return false;'
entry cardinal              pass "" encoder/cardinal.c -prover z3v4.5

# 4. Reverted bugs. f708ad5d (message encoder bounds):
# - encode_array with only the release-dropped ASSERT(from <= to): the
#   negative element count of a slice with to < from;
mutant f708ad5d-count encoder/message_encoder.render src/messaging.cc "underflow" "" \
  "if (from < 0 || from > to || to > object->length()) return false;" "ASSERT(from <= to);"
# - without the length check: the read past the backing array (the loop
#   cannot keep `to <= length`);
mutant f708ad5d-read encoder/message_encoder.render src/messaging.cc "to <= o_len|index < o_len" "" \
  "if (from < 0 || from > to || to > object->length()) return false;" "if (from < 0 || from > to) return false;"
# - encode_map without the bound on the backing: the read past it.
mutant f708ad5d-map encoder/message_encoder.render src/messaging.cc "i < o_len" "" \
  "count < size && i + 1 < limit; i += 2)" "count < size; i += 2)"
# The 32-bit size fix (README, "Findings"): a blob checked against twice
# what is left: the sizes leave the bound (on ILP32 they overflowed).
mutant encoder-copy-size encoder/message_encoder.render src/messaging.cc "1073741823 \+ 32|overflow" "" \
  "if (length > MESSAGING_ENCODING_MAX_SIZE - total_size()) {" \
  "if (length > MESSAGING_ENCODING_MAX_SIZE + MESSAGING_ENCODING_MAX_SIZE - total_size()) {"
# ... and the same for a transferred byte array.
mutant encoder-transfer-size encoder/message_encoder.render src/messaging.cc "1073741823 \+ 32|overflow" "" \
  "if (bytes.length() > MESSAGING_ENCODING_MAX_SIZE - total_size()) {" \
  "if (bytes.length() > MESSAGING_ENCODING_MAX_SIZE + MESSAGING_ENCODING_MAX_SIZE - total_size()) {"
# The external tables: one reservation too many writes past copied_ or
# transferred_.
mutant encoder-externals-bound encoder/message_encoder.render src/messaging.cc "<= 8" "" \
  "if (externals_count_ >= MESSAGING_ENCODING_MAX_EXTERNALS) {" "if (externals_count_ > MESSAGING_ENCODING_MAX_EXTERNALS) {"
# The string copy's terminator read from the content (README, "Findings"):
# one byte past the blob.
mutant encoder-copy-terminator encoder/message_encoder.render src/messaging.cc "No matching heap chunks: \[_\]chars" "" \
  "memcpy(data, source, length);" "memcpy(data, source, length + extra);"

# The message decoder (TISON from untrusted bytes; IPC under the two named
# assumptions). `-allow_dead_code`: the `return null` after decode_any's
# switch (every case returns).
DEC_OPTS="-allow_dead_code -prover z3v4.5"
mutant finalizer-delivery-keep decoder/message_decoder.render src/heap.cc "Cannot prove|No matching" "$DEC_OPTS" \
  "if (node->keep_after_callback())" "if (!node->keep_after_callback())"
mutant finalizer-delivery-detach decoder/message_decoder.render verified/cxx/annotated/model/finalizer_fifo.h "Cannot prove|No matching" "$DEC_OPTS" \
  "SOURCE::  *head = *next;\n  *next = 0;" "  *head = *next;"
mutant finalizer-ready-queue decoder/message_decoder.render src/heap.h "No matching|Cannot prove" "$DEC_OPTS" \
  "return !runnable_finalizers_.is_empty();" "return !registered_callback_finalizers_.is_empty();"
mutant finalizer-ready-inverted decoder/message_decoder.render src/heap.h "Cannot prove" "$DEC_OPTS" \
  "return !runnable_finalizers_.is_empty();" "return runnable_finalizers_.is_empty();"
mutant task-has-messages-pressure decoder/message_decoder.render src/primitive_core.cc "Cannot prove" "-allow_dead_code -prover z3v4.5" \
  "PRIMITIVE(task_has_messages)@@heap->max_external_allocation() < 0" "heap->max_external_allocation() <= 0"
mutant task-has-messages-mailbox decoder/message_decoder.render src/primitive_core.cc "Cannot prove" "-allow_dead_code -prover z3v4.5" \
  "PRIMITIVE(task_has_messages)@@return BOOL(message != null);" "return BOOL(message == null);"
mutant decoder-clear-main-arguments decoder/message_decoder.render src/process.h "No matching|Cannot prove" "$DEC_OPTS" \
  "void clear_main_arguments()@@main_arguments_ = null;" "spawn_arguments_ = null;"
entry decoder               pass "" decoder/message_decoder.gen.c -allow_dead_code -prover z3v4.5
# The bound of read_cardinal's digits (decoder/radix.h), with Z3.
# `-allow_dead_code`: on ILP32 the cases of the shifts above 28.
entry radix                 pass "" decoder/radix.c -allow_dead_code -prover z3v4.5
# The length checks before the inline copies: the copy leaves the input.
mutant decoder-string-length decoder/message_decoder.render src/messaging.cc "result (63|31)\)\) cap" "$DEC_OPTS" \
  "MessageDecoder::decode_string(bool inlined)@@if (length < 0 || length > remaining()) return mark_malformed();" "if (length < 0) return mark_malformed();"
mutant decoder-byte-array-length decoder/message_decoder.render src/messaging.cc "1073741823" "$DEC_OPTS" \
  "MessageDecoder::decode_byte_array(bool inlined)@@if (length < 0 || length > remaining()) return mark_malformed();" "if (length < 0) return mark_malformed();"
# The length checks before the array and map allocations: an allocation
# larger than the input left.
mutant decoder-array-length decoder/message_decoder.render src/messaging.cc "result (63|31)\) \(- cap" "$DEC_OPTS" \
  "if (length < 0 || length > remaining() || length > Array::max_length_in_process()) {" "if (length < 0 || length > Array::max_length_in_process()) {"
mutant decoder-map-length decoder/message_decoder.render src/messaging.cc "\(\* 2 \(truncate_signed result (63|31)\)\) \(- cap" "$DEC_OPTS" \
  "if (size < 0 || size > remaining() / 2 || size > Array::max_length_in_process() / 2) {" "if (size < 0 || size > Array::max_length_in_process() / 2) {"
# The nesting limit (#3362) taken out: the recursion is unbounded.
mutant decoder-nesting decoder/message_decoder.render src/messaging.cc "n 1\) 64" "$DEC_OPTS" \
  "  if (nesting_ > MESSAGING_DECODING_MAX_NESTING) return mark_malformed();\n" ""
# The fixed-size readers' bound: a read past the input.
mutant decoder-uint64-bound decoder/message_decoder.render src/messaging.cc "8 \(- cap c\)" "$DEC_OPTS" \
  "MessageDecoder::read_uint64()@@if (next <= size_) {" "if (next <= size_ + 1) {"
# read_uint8, in the header (mutant.sh copies the changed header into the
# mutant's src/): the byte at the end of the input is read.
mutant decoder-uint8-bound decoder/message_decoder.render src/messaging.h "No matching|uchars|cap" "$DEC_OPTS" \
  "return (cursor < size_) ? buffer_[cursor] : 0;" "return (cursor <= size_) ? buffer_[cursor] : 0;"
# read_cardinal_64: without the size check (#3362) the shift is
# undefined; without the digit check (wave 3) the sum wraps.
mutant decoder-cardinal-shift decoder/message_decoder.render src/messaging.cc "shift|7 \* k|digit|overflow" "$DEC_OPTS" \
  "if (shift >= 64 || digit > (UINT64_MAX >> shift)) {" "if (digit > (UINT64_MAX >> shift)) {"
mutant decoder-cardinal-digit decoder/message_decoder.render src/messaging.cc "18446744073709551615|overflow|digit" "$DEC_OPTS" \
  "if (shift >= 64 || digit > (UINT64_MAX >> shift)) {" "if (shift >= 64) {"
# read_cardinal: a 64-bit cardinal is not a word on ILP32 (on LP64 the
# check is dead): without the check the conversion to uword overflows.
mutant decoder-cardinal-word decoder/message_decoder.render src/messaging.cc "ILP32:overflow|truncat|uword" "$DEC_OPTS" \
  "  if (result > UINTPTR_MAX) {\n    mark_malformed();\n    return 0;\n  }\n  return static_cast<uword>(result);" "  return static_cast<uword>(result);"
# Finding 3 (wave 4): the smi tags' magnitude above INT64_MAX (the
# conversion to int64 overflows); without the smi range check in
# decode_integer a value in the smi range is allocated as a large integer
# (not canonical: decode_integer's postcondition, a smi for a value in the
# smi range, fails; until wave 6 the allocator's `canonical` clause did).
mutant decoder-smi-magnitude decoder/message_decoder.render src/messaging.cc "overflow|int64|9223372036854775807" "$DEC_OPTS" \
  "case TAG_POSITIVE_SMI: {\n      uint64 value = read_cardinal_64();\n      if (value > static_cast<uint64>(INT64_MAX)) return mark_malformed();\n" "case TAG_POSITIVE_SMI: {\n      uint64 value = read_cardinal_64();\n"
mutant decoder-negative-smi-magnitude decoder/message_decoder.render src/messaging.cc "overflow|int64|9223372036854775807" "$DEC_OPTS" \
  "case TAG_NEGATIVE_SMI: {\n      uint64 value = read_cardinal_64();\n      if (value > static_cast<uint64>(INT64_MAX)) return mark_malformed();\n" "case TAG_NEGATIVE_SMI: {\n      uint64 value = read_cardinal_64();\n"
mutant decoder-integer-canonical decoder/message_decoder.render src/messaging.cc "smi_range|smi_val|is_smi_w" "$DEC_OPTS" \
  "  if (Smi::is_valid(value)) return Smi::from(static_cast<word>(value));\n" ""
# decode_external_data (the external message handlers, wave 4): without
# the inline length check the int conversion and the copy's length are
# unbounded (a negative int was a huge memcpy).
mutant decoder-external-inline-length decoder/message_decoder.render src/messaging.cc "pow_nat|truncate|<= 0 n|overflow|underflow" "$DEC_OPTS" \
  "    // As in decode_byte_array: the inline content is in the message.\n    word cardinal = read_cardinal();\n    if (cardinal < 0 || cardinal > remaining()) {\n      mark_malformed();\n      return false;\n    }\n" "    // As in decode_byte_array: the inline content is in the message.\n    word cardinal = read_cardinal();\n"
mutant decoder-external-string-length decoder/message_decoder.render src/messaging.cc "pow_nat|truncate|<= 0 n|overflow|underflow" "$DEC_OPTS" \
  "  } else if (tag == TAG_STRING_INLINE) {\n    word cardinal = read_cardinal();\n    if (cardinal < 0 || cardinal > remaining()) {\n      mark_malformed();\n      return false;\n    }\n" "  } else if (tag == TAG_STRING_INLINE) {\n    word cardinal = read_cardinal();\n"
# The externals table: one entry too many is written past it.
mutant decoder-externals-bound decoder/message_decoder.render src/messaging.cc "pointers|intptrs|No matching|<= 8|index" "$DEC_OPTS" \
  "if (index >= ARRAY_SIZE(externals_)) {" "if (index > ARRAY_SIZE(externals_)) {"
# The ownership of a message's out-of-line blocks (wave 5). The malformed
# message delivered as decoded (the fix of 05159afd taken out): the blocks
# after the error stay with nobody (dec_finish needs a success).
mutant receive-malformed-delivered decoder/message_decoder.render src/primitive_core.cc "MALFORMED|st != 2|2 != st|Cannot prove" "$DEC_OPTS" \
  "PRIMITIVE(task_receive_message)@@if (decoder.malformed_input()) {" "if (false && decoder.malformed_input()) {"
mutant arguments-malformed-delivered decoder/message_decoder.render src/primitive_core.cc "MALFORMED|st != 2|2 != st|Cannot prove" "$DEC_OPTS" \
  "PRIMITIVE(main_arguments)@@if (decoder.malformed_input()) {" "if (false && decoder.malformed_input()) {"
# A failed decode that keeps the objects' finalizers: the lent blocks are
# not the message's again (a double free when the message is retried or
# deleted).
mutant receive-no-give-back decoder/message_decoder.render src/primitive_core.cc "dec_back|No matching" "$DEC_OPTS" \
  "PRIMITIVE(task_receive_message)@@decoder.remove_disposing_finalizers();" "decoder.success();"
# One finalizer bit left set: its block is still lent.
mutant receive-give-back-bound decoder/message_decoder.render src/messaging.cc "lent|finalized|invariant|Cannot prove|No matching" "$DEC_OPTS" \
  "MessageDecoder::remove_disposing_finalizers()@@for (unsigned i = 0; i < externals_count(); i++)" "for (unsigned i = 0; i + 1 < externals_count(); i++)"
# A dropped message freed without its blocks (a leak): the message is
# whole again (msg_whole), which free does not take.
mutant arguments-drop-leak decoder/message_decoder.render src/primitive_core.cc "leak|msg_blocks|malloc_block" "$DEC_OPTS" \
  "PRIMITIVE(main_arguments)@@MessageDecoder::deallocate(arguments);" "free(arguments);"
# A decoded message freed with its blocks: the objects own them (a double
# free when their finalizers run).
mutant receive-success-free-all decoder/message_decoder.render src/primitive_core.cc "msg_whole|No matching" "$DEC_OPTS" \
  "system_message->free_data_but_keep_externals();" "system_message->free_data_and_externals();"
# A block lent to an object that is not in the externals table: nobody can
# give it back.
mutant decoder-unregistered-block decoder/message_decoder.render src/messaging.cc "dec_pend|leak|Cannot prove|No matching" "$DEC_OPTS" \
  "    if (result) register_external(result, length);\n" ""
# The deallocation walk: a block freed twice, a block not freed.
mutant deallocate-double-free decoder/message_decoder.render src/messaging.cc "malloc_block|No matching" "$DEC_OPTS" \
  "      read_cardinal();\n      free(read_pointer());" "      read_cardinal();\n      { uint8* p = read_pointer(); free(p); free(p); }"
mutant deallocate-leak decoder/message_decoder.render src/messaging.cc "leak|malloc_block" "$DEC_OPTS" \
  "      read_cardinal();\n      free(read_pointer());" "      read_cardinal();\n      read_pointer();"

mutant finalizer-roots-weak-closure prims/finalizers.render src/heap_roots.cc "Cannot prove" "-prover z3v4.5" \
  "void WeakMapFinalizerNode::roots_do@@  cb->do_root(reinterpret_cast<Object**>(&lambda_));" ""
mutant finalizer-roots-ordinary-duplicate prims/finalizers.render src/heap_roots.cc "Cannot prove" "-prover z3v4.5" \
  "void ToitFinalizerNode::roots_do@@  cb->do_root(reinterpret_cast<Object**>(&lambda_));" "  cb->do_root(reinterpret_cast<Object**>(&key_));"
entry byte-array-ownership pass "" model/byte_array_ownership.gen.c -prover z3v4.5
mutant byte-array-ownership-borrowed model/byte_array_ownership.render src/objects.h "Cannot prove" "-prover z3v4.5" \
  'return has_active_finalizer();' 'return true;'
entry finalizer-primitives pass "" prims/finalizers.gen.c -prover z3v4.5
mutant finalizer-primitives-unlink-tail prims/finalizers.render src/heap.cc "Cannot prove|No matching" "-prover z3v4.5" \
  "SIDECAR::      if (next == 0) queue->tail_ = prev;" ""
mutant finalizer-primitives-unlink-key prims/finalizers.render src/heap.cc "Cannot prove|No matching" "-prover z3v4.5" \
  "SIDECAR::bool discard = (uword)current->key_ == (uword)key;" "bool discard = (uword)current->key_ != (uword)key;"
mutant finalizer-primitives-lost-tail prims/finalizers.render verified/cxx/annotated/model/finalizer_nodes.h "Cannot prove|No matching" "-prover z3v4.5" \
  "SOURCE::  callback_prepend_links((void **)&q->anchor_.next_, (void **)&q->tail_, (void **)&n->next_, n);" \
  "  callback_prepend_links((void **)&q->anchor_.next_, (void **)&q->tail_, (void **)&n->next_, n);\n  q->tail_ = n;"
mutant finalizer-primitives-readonly prims/finalizers.render src/primitive_core.cc "Cannot prove" "-prover z3v4.5" \
  "if (object->on_program_heap(process)) return BOOL(false);" "if (false) return BOOL(false);"
mutant finalizer-primitives-instance prims/finalizers.render src/primitive_core.cc "Cannot prove" "-prover z3v4.5" \
  "PRIMITIVE(remove_finalizer)@@  if (!is_instance(object)) return BOOL(false);" ""
mutant finalizer-primitives-weak prims/finalizers.render src/primitive_core.cc "Cannot prove" "-prover z3v4.5" \
  "PRIMITIVE(add_finalizer)@@    make_weak = true;" "    make_weak = false;"
mutant finalizer-primitives-duplicate prims/finalizers.render src/primitive_core.cc "Cannot prove" "-prover z3v4.5" \
  "if (already_active) FAIL(ALREADY_EXISTS);" "if (!already_active) FAIL(ALREADY_EXISTS);"
mutant finalizer-primitives-allocation prims/finalizers.render src/primitive_core.cc "Cannot prove" "-prover z3v4.5" \
  "finalizer, make_weak)) FAIL(MALLOC_FAILED);" "finalizer, make_weak)) FAIL(ALREADY_EXISTS);"
mutant finalizer-primitives-header model/byte_array_ownership.render src/objects.h "Cannot prove" "-prover z3v4.5" \
  "if (has_forwarding_address()) {\n      target = forwarding_address();" "if (false) {\n      target = forwarding_address();"
mutant finalizer-primitives-node-kind prims/finalizers.render src/heap.cc "Cannot prove" "-prover z3v4.5" \
  "auto weak_node = _new WeakMapFinalizerNode" "auto weak_node = _new ToitFinalizerNode"
mutant finalizer-primitives-node-callback prims/finalizers.render src/heap_roots.h "Cannot prove" "-prover z3v4.5" \
  "FinalizerNode(key, heap), lambda_(lambda)" "FinalizerNode(key, heap), lambda_(key)"
mutant finalizer-primitives-missing-set prims/finalizers.render src/heap.cc "No matching|Cannot prove" "-prover z3v4.5" \
  "bool ObjectHeap::add_callable_finalizer@@  key->set_has_active_finalizer();" ""
mutant finalizer-primitives-missing-clear prims/finalizers.render src/heap.cc "No matching|Cannot prove" "-prover z3v4.5" \
  "void ObjectHeap::remove_callable_finalizer@@  key->clear_has_active_finalizer();" ""
mutant finalizer-primitives-set-mask prims/finalizers.render src/objects.h "Cannot prove" "-prover z3v4.5" \
  "header_word |= 1 << HeapObject::FINALIZER_BIT_OFFSET;" "header_word |= 2 << HeapObject::FINALIZER_BIT_OFFSET;"
entry byte-content          pass "" blob/byte_content.gen.c
mutant byte-content-finalizer-map blob/byte_content.render src/objects.cc "Cannot prove" "" \
  "if (is_instance(this) && class_id() == program->map_class_id())" "if (is_instance(this) && class_id() != program->map_class_id())"
mutant byte-content-finalizer-view blob/byte_content.render src/objects.cc "Cannot prove" "" \
  "    // the header, and it's also for VM finalizers, that free external memory.\n    return false;" "    return true;"
mutant byte-content-slice-length blob/byte_content.render src/objects.cc "decoded_length" "" \
  "*length = to_value - from_value;" "*length = 0;"
# 357d1127 (#3373, byte_content nesting) reverted: without the depth limit
# the recursive call's precondition (depth + 1 <= MAX) fails.
mutant byte-content-357d1127 blob/byte_content.render src/objects.cc "depth" "" \
  "    if (depth >= MAX_BYTE_CONTENT_DEPTH) return false;" ""
# A slice's `to` not checked against the content: the pointer leaves the blob.
mutant byte-content-slice-to blob/byte_content.render src/objects.cc "pointer_within_limits|blob_in" "" \
  "from_value <= to_value && to_value <= *length) {" "from_value <= to_value) {"

entry utf8-validator        pass "" utf8/validator.gen.c
for target in LP64 ILP32; do
  if [[ "utf8-wp/$target" == *"$filter"* ]]; then spawn ./utf8/wp.sh "$target"; fi
done
entry utf16-to-8            pass "" utf8/utf_16_to_8.gen.c -prover z3v4.5
mutant utf16-to-8-byte-order utf8/utf_16_to_8.render src/utils.cc "Cannot prove" "-prover z3v4.5" \
  "return input[offset] + (input[offset + 1] << 8);" "return input[offset + 1] + (input[offset] << 8);"
mutant utf16-to-8-write-count prims/blob_validation.render src/primitive_core.cc "Cannot prove" "-allow_dead_code -prover z3v4.5" \
  "return written == output.length();" "return written >= 0;"
mutant utf16-to-8-byte utf8/utf_16_to_8.render src/utils.cc "Cannot prove" "-prover z3v4.5" \
  "output[size]     = 0xf0 + (c >> 18);" "output[size]     = 0xe0 + (c >> 18);"
mutant utf16-to-8-unpaired utf8/utf_16_to_8.render src/utils.cc "Cannot prove" "-prover z3v4.5" \
  "int decoded = 0xfffd;" "int decoded = 0xfffc;"
mutant utf16-to-8-capacity utf8/utf_16_to_8.render src/utils.cc "Cannot prove|No matching" "-prover z3v4.5" \
  "if (size + 2 >= output_length) return -1;" "if (size + 2 > output_length) return -1;"
entry utf8                  pass "" utf8/utf_8_to_16.gen.c -prover z3v4.5
mutant utf8-sizing-error utf8/utf_8_to_16.render src/utils.cc "Cannot prove" "-prover z3v4.5" \
  "word Utils::utf_8_to_16@@  return size;" "  return output ? size : -1;"
mutant utf8-surrogate-count utf8/utf_8_to_16.render src/utils.cc "utf16_units" "-prover z3v4.5" \
  "word Utils::utf_8_to_16@@      size += 2;" "      size += 1;"
mutant utf8-surrogate-write utf8/utf_8_to_16.render src/utils.cc "initialized_units" "-prover z3v4.5" \
  "        output[size + 1] = 0xdc00 + (c & 0x3ff);" ""
# 07c24665 (UTF-8 decoding read past the input) reverted: the first byte
# announcing 1 or more than 4 bytes reaches payload_from_prefix (the UB
# shift `1 << (7 - 8)` the first pilot's tools found)...
mutant utf8-07c24665 utf8/utf_8_to_16.render src/utils.cc "utf8_count" "-prover z3v4.5" \
  "if (prefix > Utils::MAX_ASCII && (count < 2 || count > 4 || count > length - i)) {\n      c = 0xfffd;\n      count = 1;\n    } else if (prefix > Utils::MAX_ASCII) {" \
  "if (prefix > Utils::MAX_ASCII) {"
# ... and with only its length check taken out, the continuation bytes
# cannot be shown to fit in the remaining input.
mutant utf8-overread utf8/utf_8_to_16.render src/utils.cc "Cannot prove \(<= count[0-9]* \(- length[0-9]* i" "-prover z3v4.5" \
  "count > 4 || count > length - i)" "count > 4)"

# The Rust/C++ boundary of src/interpreter_v2.cc (wave 6; stack growth
# since wave 1): the leaf contracts of CONTRACTS.toml. `-allow_dead_code`:
# the trace of Flags::primitives, a constant false in release builds.
FFI_OPTS="-allow_dead_code -prover z3v4.5"
entry ffi                   pass "" ffi/interpreter_v2.gen.c -allow_dead_code -prover z3v4.5
entry array-init            pass "" ffi/array_init.gen.c -prover z3v4.5
mutant array-init-skip-slot ffi/array_init.render src/objects.h "invariant|Cannot prove condition|No matching heap chunks" "-prover z3v4.5" \
  "void _initialize_no_write_barrier(word length, Object* filler)@@index < length;" "index + 1 < length;"
mutant ffi-gc-dispatch-barrier ffi/interpreter_v2.render src/interpreter_v2.cc "remembered_stack" "$FFI_OPTS" \
  "static void v2_gc(Process* process@@  GcMetadata::insert_into_remembered_set(process->task()->stack());" ""
mutant ffi-gc-dispatch-mode ffi/interpreter_v2.render src/interpreter_v2.cc "gc_returned" "$FFI_OPTS" \
  "scheduler()->gc(process, malloc_failed, attempts > 1 || force_cross_process);" "scheduler()->gc(process, malloc_failed, attempts > 1);"
mutant ffi-gc-dispatch-report ffi/interpreter_v2.render src/interpreter_v2.cc "gc_returned|gc_action|allocation_reported" "$FFI_OPTS" \
  "static void v2_gc(Process* process@@if (attempts == 3)" "if (attempts == 2)"
mutant ffi-array-filler ffi/interpreter_v2.render src/interpreter_v2.cc "all_eq" "$FFI_OPTS" \
  "length, static_cast<Object*>(filler)));" "length, static_cast<Object*>(nullptr)));"
mutant ffi-error-tag ffi/interpreter_v2.render src/primitive.h "is_marked|Cannot prove condition" "$FFI_OPTS" \
  "== Object::MARKED_TAG;" "!= Object::MARKED_TAG;"
# An immediate error must name an existing root even when no primitive
# promises which marked word it returned. The first unused index matters.
mutant ffi-error-root-bound ffi/interpreter_v2.render src/primitive.cc "Cannot prove.*shiftright.*35" "$FFI_OPTS" \
  "if (index >= Program::ROOT_COUNT)" "if (index > Program::ROOT_COUNT)"
mutant ffi-slot-position ffi/interpreter_v2.render src/objects.h "Cannot prove.*result|Cannot prove.*slot" "$FFI_OPTS" \
  "_array_address(length() - 1 - position)" "_array_address(length() - position)"
mutant ffi-stack-top-offset ffi/interpreter_v2.render src/objects.h "Cannot prove.*result top" "$FFI_OPTS" \
  "word top() const@@return _word_at(TOP_OFFSET);" "return _word_at(LENGTH_OFFSET);"
mutant ffi-record-low-bit ffi/interpreter_v2.render src/objects.h "Cannot prove.*rtop" "$FFI_OPTS" \
  "v2_records_word() & (V2_MAX_LENGTH - 1)" "(v2_records_word() & (V2_MAX_LENGTH - 1)) / 2"
mutant ffi-pack-frame ffi/interpreter_v2.render src/objects.h "Cannot prove.*frame_top.*div" "$FFI_OPTS" \
  "_set_try_top(record_top | (frame_top << V2_FRAME_TOP_SHIFT));" "_set_try_top(record_top);"
mutant ffi-store-bci ffi/interpreter_v2.render src/objects.h "Cannot prove.*bci.*truncate_signed" "$FFI_OPTS" \
  "void v2_set_records(word frame_top, word fin_count, word bci)@@_word_at_put(PENDING_STACK_CHECK_METHOD_OFFSET, bci);" \
  "_word_at_put(PENDING_STACK_CHECK_METHOD_OFFSET, bci < 0 ? static_cast<word>(0) : bci);"
mutant ffi-epoch-wrap ffi/interpreter_v2.render src/heap.h "Cannot prove.*epoch_word" "$FFI_OPTS" \
  "v2_epoch_ = v2_epoch_ + 1;" "v2_epoch_ = v2_epoch_ == UINTPTR_MAX ? v2_epoch_ : v2_epoch_ + 1;"
mutant ffi-epoch-publication ffi/interpreter_v2.render src/heap.h "Cannot prove n ==" "$FFI_OPTS" \
  "task_ = task; advance_v2_epoch();" "task_ = task;"
mutant ffi-task-read-field ffi/interpreter_v2.render src/objects.h "No matching.*pointer" "$FFI_OPTS" \
  "return Stack::cast(at(STACK_INDEX));" "return Stack::cast(at(STACK_INDEX + 1));"
mutant ffi-task-write-barrier ffi/interpreter_v2.render src/objects_inline.h "No matching.*remembered_instance" "$FFI_OPTS" \
  "inline void Instance::at_put(word index, Object* value)@@  GcMetadata::insert_into_remembered_set(this);" ""
mutant ffi-task-late-barrier ffi/interpreter_v2.render src/objects_inline.h "No matching.*remembered_instance" "$FFI_OPTS" \
  "inline void Instance::at_put(word index, Object* value)@@  GcMetadata::insert_into_remembered_set(this);" "" \
  "inline void Instance::at_put(word index, Object* value)@@  _at_put(_offset_from(index), value);" \
  "  _at_put(_offset_from(index), value);\n  GcMetadata::insert_into_remembered_set(this);"
mutant grow-stack-stale-task ffi/interpreter_v2.render src/interpreter_v2.cc "Cannot prove.*= saved_task" "$FFI_OPTS" \
  "uword toit_v2_grow_stack(void* raw_process, uword needed)@@  Stack* stack = process->task()->stack();" \
  "  Task* saved_task = process->task();\n  Stack* stack = saved_task->stack();" \
  "uword toit_v2_grow_stack(void* raw_process, uword needed)@@  stack = process->task()->stack();" \
  "  stack = saved_task->stack();"
mutant grow-stack-missing-slots ffi/interpreter_v2.render src/objects_runtime.cc "Cannot prove.*same_abstraction" "$FFI_OPTS" \
  "void Stack::v2_copy_to(Stack* other)@@  memcpy(other->_array_address(top() + displacement), _array_address(top()), used * WORD_SIZE);" ""
# The bound on `needed` (core/trusted-integration) taken out again: the
# cast to word overflows; with only the cast made exact by a precondition,
# the sum.
mutant grow-stack-unbounded ffi/interpreter_v2.render src/interpreter_v2.cc "overflow|underflow" "$FFI_OPTS" \
  "  if (needed > static_cast<uword>(Stack::max_length())) return TOIT_V2_STACK_OVERFLOW;\n" ""
mutant grow-stack-word-range ffi/interpreter_v2.render src/interpreter_v2.cc "overflow" "$FFI_OPTS" \
  "  if (needed > static_cast<uword>(Stack::max_length())) return TOIT_V2_STACK_OVERFLOW;\n" "" \
  "uword toit_v2_grow_stack(void* raw_process, uword needed)@@//@ requires vm((Process *)raw_process, ?a, ?n);" \
  "//@ requires vm((Process *)raw_process, ?a, ?n) &*& needed <= UINTPTR_MAX / 2;"
# The primitive call without its arity check: a primitive of another arity
# reads arguments outside the frame (its precondition fails).
mutant ffi-primitive-arity ffi/interpreter_v2.render src/interpreter_v2.cc "prim_arity" "$FFI_OPTS" \
  "if (primitive == null || static_cast<uword>(primitive->arity) != arity) return TOIT_V2_PRIMITIVE_ABSENT;" \
  "if (primitive == null) return TOIT_V2_PRIMITIVE_ABSENT;"
# The retry after a GC with the stack read before the GC (moved or
# shrunk: the arguments' address is not the current stack's).
mutant ffi-primitive-stale-stack ffi/interpreter_v2.render src/interpreter_v2.cc "v_s|stack_array|remembered_stack" "$FFI_OPTS" \
  "SOURCE::    v2_gc(process, malloc_failed" "    Stack* stack = process->task()->stack();\n    v2_gc(process, malloc_failed" \
  "SOURCE::    Stack* stack = process->task()->stack();\n    // A moving collection" "    // A moving collection" \
  "SIDECAR::    v2_gc(process, malloc_failed" "    //@ open vm(process, bc, nc);\n    Stack* stack = process->task()->stack();\n    //@ close vm(process, bc, nc);\n    v2_gc(process, malloc_failed" \
  "SIDECAR::    //@ same_frames_facts(a, bg);\n    Stack* stack = process->task()->stack();" "    //@ same_frames_facts(a, bg);"
mutant ffi-gc-dispatch-retry-barrier ffi/interpreter_v2.render src/interpreter_v2.cc "remembered_stack" "$FFI_OPTS" \
  "static __attribute__((noinline)) V2_HOT uword v2_primitive_failed(@@    GcMetadata::insert_into_remembered_set(stack);" ""
# The primitive retry loop one attempt longer: more collections than the
# epoch accounting allows (an unchanged epoch word would no longer mean
# that nothing moved).
mutant ffi-primitive-retries ffi/interpreter_v2.render src/interpreter_v2.cc "attempts|<= 4|invariant|Cannot prove" "$FFI_OPTS" \
  "    if (attempts > 3) {" "    if (attempts > 4) {"
# The allocation retry loop without its bound (both instances of the
# template): unbounded collections, the epoch could wrap.
mutant ffi-allocate-retries ffi/interpreter_v2.render src/interpreter_v2.cc "attempts|<= 4|n \+ 3|invariant|Cannot prove" "$FFI_OPTS" \
  "SOURCE::  for (int attempts = 1; result == null && attempts < 4; attempts++) {" \
  "  for (int attempts = 1; result == null; attempts++) {" \
  "SIDECAR::lambda=toit_v2_allocate_instance@@  for (int attempts = 1; result == null && attempts < 4; attempts++)" \
  "  for (int attempts = 1; result == null; attempts++)" \
  "SIDECAR::lambda=toit_v2_allocate_double@@  for (int attempts = 1; result == null && attempts < 4; attempts++)" \
  "  for (int attempts = 1; result == null; attempts++)"

# The sender side of the external message handlers (wave 6): the ownership
# of the encoded buffer and of the caller's data on every path.
SEND_OPTS="-allow_dead_code -prover z3v4.5"
entry sender                pass "" sender/external_send.gen.c -allow_dead_code -prover z3v4.5
# The fix of the encoder's one-argument constructor reverted (README,
# "Findings", wave 6): the encoder does not own its buffer, and send_'s
# failure path (the message not allocated) leaks it.
mutant sender-encoder-owns-buffer sender/external_send.render src/messaging.h "take_ownership|leak|Cannot prove" "$SEND_OPTS" \
  "explicit MessageEncoder(uint8* buffer) : buffer_(buffer), take_ownership_of_buffer_(true)" \
  "explicit MessageEncoder(uint8* buffer) : buffer_(buffer)"
# The data freed on a failure without free_on_failure: the caller still
# owns it (a double free when it frees it).
mutant sender-free-callers-data sender/external_send.render src/messaging.cc "block|No matching|Cannot prove" "$SEND_OPTS" \
  "ExternalSystemMessageHandler::send_(int pid, int type, void* data, word length, bool free_on_failure)@@    if (free_on_failure) free(data);" \
  "    free(data);" \
  "SIDECAR::    if (free_on_failure) /*@ open block(data); @*/ free(data);" "    /*@ open block(data); @*/ free(data);"
# A failed send without free_on_failure deletes the message with its
# buffer: the deletion frees the data the caller still owns.
mutant sender-delete-with-buffer sender/external_send.render src/messaging.cc "sys_msg|No matching|Cannot prove" "$SEND_OPTS" \
  "    system_message->free_data_but_keep_externals();\n    delete system_message;" "    delete system_message;"

entry string-write          pass "" prims/string_write.gen.c -prover z3v4.5
# af4ba7ab (memcpy for a copy within one byte array) reverted: no proof...
mutant string-write-af4ba7ab prims/string_write.render src/primitive_core.cc "No matching heap chunks: uchars_" "-prover z3v4.5" \
  "  memmove(&dest.address()[dest_index]" "  memcpy(&dest.address()[dest_index]"
# ... and with the two ranges assumed to be in different byte arrays
# (separate chunks for memcpy), the same memcpy verifies: the failure is
# the overlap.
mutant string-write-af4ba7ab-disjoint prims/string_write.render src/primitive_core.cc PASS "-allow_assume -allow_dead_code -prover z3v4.5" \
  "  memmove(&dest.address()[dest_index]" "  memcpy(&dest.address()[dest_index]" \
  "  //@ if (bs != bd) blob_take(bs);" "  //@ assume(bs != bd);\n  //@ blob_take(bs);" \
  "    close mm_pre(mm_two, d, s, to - from);\n" "" \
  "    open mm_post(_, _, _, _);\n    uchars_join(s);" "    uchars_join(s);"

entry blob-args             pass "" prims/blob_args.gen.c
entry primitive-integer     pass "" prims/integer.gen.c -prover z3v4.5
mutant primitive-integer-range prims/integer.render src/primitive.h "smi_range|Cannot prove|overflow" "-prover z3v4.5" \
  "if (Smi::is_valid(value)) return Smi::from((word) value);" "if (Smi::is_valid(0)) return Smi::from((word) value);"
entry primitive-random      pass "" prims/random.gen.c -prover z3v4.5
mutant primitive-random-seed-length prims/random.render src/process.cc "Cannot prove|No matching" "-prover z3v4.5" \
  "size -= sizeof(random_state0_);" ""
mutant primitive-random-seed-failure prims/random.render src/process.cc "Cannot prove|No matching" "-prover z3v4.5" \
  "if (!EntropyMixer::instance()->get_entropy(seed, sizeof(seed))) {@@    memset(seed, 0x42, sizeof(seed));" ""
mutant primitive-random-state prims/random.render src/process.cc "Cannot prove" "-prover z3v4.5" \
  "random_state1_ = s1;" "random_state1_ = s0;"
mutant primitive-random-mask prims/random.render src/primitive_core.cc "Cannot prove" "-prover z3v4.5" \
  "return Smi::from(process->random() & 0xfffffff);" "return Smi::from(process->random() & 0x7ffffff);"
entry primitive-time        pass "" prims/time.gen.c -prover z3v4.5
mutant primitive-time-rtc-field prims/time.render src/primitive_core.cc "Cannot prove" "-prover z3v4.5" \
  "result->at_put(1, tv_nsec);" "result->at_put(1, tv_sec);"
mutant primitive-time-rtc-error prims/time.render src/primitive_core.cc "Cannot prove|No matching" "-prover z3v4.5" \
  "if (Primitive::is_error(tv_nsec)) return tv_nsec;" ""
spawn entry_run LP64 format-integer pass "" prims/format_integer.gen.c -prover z3v4.5
# ARGS(int) has an unreachable narrowing failure on ILP32.
defer entry_run ILP32 format-integer pass "" prims/format_integer.gen.c -allow_dead_code -prover z3v4.5
mutant format-integer-radix prims/format_integer.render src/primitive_core.cc "Cannot prove|No matching" "-prover z3v4.5" \
  "PRIMITIVE(printf_style_int64_to_string)@@base != 2 && base != 8 && base != 16" "base != 2 && base != 8 && base != 10 && base != 16"
mutant format-integer-unsigned prims/format_integer.render src/primitive_core.cc "Cannot prove|No matching" "-prover z3v4.5" \
  "return format_integer(process, value, 10, true);" "return format_integer(process, value, 10, false);"
mutant format-integer-capacity prims/format_integer.render src/primitive_core.cc "Cannot prove|No matching" "-prover z3v4.5" \
  "uint8 buffer[65];" "uint8 buffer[64];"
mutant format-integer-letter prims/format_integer.render src/primitive_core.cc "Cannot prove" "-prover z3v4.5" \
  "'a' + (digit - 10)" "'b' + (digit - 10)"
mutant format-integer-sign prims/format_integer.render src/primitive_core.cc "Cannot prove" "-prover z3v4.5" \
  "buffer[start] = '-';" "buffer[start] = '+';"
mutant format-integer-quotient prims/format_integer.render src/primitive_core.cc "Cannot prove" "-prover z3v4.5" \
  "case 16: return value / 16;" "case 16: return value / 8;"
entry shortest-decimal pass "" prims/shortest_decimal.gen.c -prover z3v4.5
mutant shortest-decimal-significand prims/shortest_decimal.render src/dtoa.cc "Cannot prove|No matching" "-prover z3v4.5" \
  "significand >= 100000000000000000ULL" "significand > 100000000000000000ULL"
mutant shortest-decimal-terminator prims/shortest_decimal.render src/dtoa.cc "Cannot prove|No matching" "-prover z3v4.5" \
  "buffer[pos] = '\0';" "buffer[pos] = '0';"
mutant float-format-shortest-zero prims/float_format.render src/primitive_core.cc "Cannot prove" "-allow_dead_code -prover z3v4.5" \
  "classification == FP_ZERO" "classification == FP_NAN"
# On LP64 every int fits the Smi used as a VM string length.
spawn entry_run LP64 float-format pass "" prims/float_format.gen.c -allow_dead_code -prover z3v4.5
defer entry_run ILP32 float-format pass "" prims/float_format.gen.c -prover z3v4.5
mutant float-format-suffix-room prims/float_format.render src/primitive_core.cc "No matching|bounds|Cannot prove" "-allow_dead_code -prover z3v4.5" \
  "capacity - written >= 3" "capacity - written >= 2"
mutant float-format-retry-overflow prims/float_format.render src/primitive_core.cc "overflow|Cannot prove" "-allow_dead_code -prover z3v4.5" \
  "written > INT_MAX - 3" "written > INT_MAX - 1"
spawn entry_run LP64 float-parse pass "" prims/float_parse.gen.c -prover z3v4.5
defer entry_run ILP32 float-parse pass "" prims/float_parse.gen.c -allow_dead_code -prover z3v4.5
mutant float-parse-embedded-nul prims/float_parse.render src/primitive_core.cc "Cannot prove|No matching" "-prover z3v4.5" \
  "return end == start + length;" "return end <= start + length;"
mutant float-parse-terminator prims/float_parse.render src/primitive_core.cc "Cannot prove|No matching" "-prover z3v4.5" \
  "copy[length] = 0;" "copy[length] = 1;"
mutant float-parse-free prims/float_parse.render src/primitive_core.cc "leak" "-prover z3v4.5" \
  "PRIMITIVE(float_parse)@@free(copy);" "(void)copy;"
mutant float-parse-length prims/float_parse.render src/primitive_core.cc "Cannot prove|No matching" "-prover z3v4.5" \
  "PRIMITIVE(float_parse)@@0 <= from && from < to && to <= input.length()" "0 <= from && from < to"
entry float-round-boxing pass "" prims/boxed_double.gen.c -prover z3v4.5
spawn entry_run LP64 float-round pass "" prims/float_round.gen.c -prover z3v4.5
# On ILP32 a Smi converted to int cannot take the narrowing error branch.
defer entry_run ILP32 float-round pass "" prims/float_round.gen.c -allow_dead_code -prover z3v4.5
mutant float-round-scale prims/float_round.render src/primitive_core.cc "Cannot prove" "-prover z3v4.5" \
  "factor *= 10;" "factor *= 9;"
mutant float-round-precision prims/float_round.render src/primitive_core.cc "Cannot prove" "-prover z3v4.5" \
  "if (factor == 0) FAIL(INVALID_ARGUMENT);" "if (factor < 0) FAIL(INVALID_ARGUMENT);"
spawn entry_run LP64 array-new-allocation pass "" prims/array_allocation.gen.c -prover z3v4.5
defer entry_run ILP32 array-new-allocation pass "" prims/array_allocation.gen.c -prover z3v4.5
spawn entry_run LP64 array-new pass "" prims/array_new.gen.c -prover z3v4.5
# An ILP32 smi always fits the int decoded by ARGS.
defer entry_run ILP32 array-new pass "" prims/array_new.gen.c -allow_dead_code -prover z3v4.5
mutant array-new-length prims/array_new.render src/primitive_core.cc "Cannot prove" "-allow_dead_code -prover z3v4.5" \
  "PRIMITIVE(array_new)@@return Primitive::allocate_array(length, filler, process);" "return Primitive::allocate_array(length - 1, filler, process);"
entry integer-division pass "" prims/integer_division.gen.c -prover z3v4.5
mutant integer-division-boxed-zero prims/integer_division.render src/primitive_core.cc "zero|Cannot prove" "-prover z3v4.5" \
  "PRIMITIVE(smi_divide)@@int64 other = LargeInteger::cast(arg)->value();\n  if (other == 0) return Primitive::mark_as_error(process->program()->division_by_zero());" "int64 other = LargeInteger::cast(arg)->value();"
mutant integer-division-quotient prims/integer_division.render src/primitive_core.cc "Cannot prove" "-prover z3v4.5" \
  "return value == INT64_MIN ? value : -value;" "return value == INT64_MIN ? value : value;"
spawn entry_run LP64 int-parse pass "" prims/int_parse.gen.c -prover z3v4.5
# The ARGS(int) narrowing check is unreachable when word and int have equal width.
defer entry_run ILP32 int-parse pass "" prims/int_parse.gen.c -allow_dead_code -prover z3v4.5
mutant int-parse-input-bound prims/int_parse.render src/primitive_core.cc "Cannot prove|No matching" "-prover z3v4.5" \
  "PRIMITIVE(int_parse)@@0 <= from && from < to && to <= input.length()" "0 <= from && from < to"
mutant int-parse-length prims/int_parse.render src/primitive_core.cc "Cannot prove" "-prover z3v4.5" \
  "if (to - from > 18) FAIL(OUT_OF_RANGE);" "if (to - from > 19) FAIL(OUT_OF_RANGE);"
mutant int-parse-digit prims/int_parse.render src/primitive_core.cc "Cannot prove" "-prover z3v4.5" \
  "magnitude * 10 + (c - '0')" "magnitude * 9 + (c - '0')"
mutant int-parse-separator prims/int_parse.render src/primitive_core.cc "Cannot prove" "-prover z3v4.5" \
  "if (index == first || index == length - 1) return false;" "if (index == first) return false;"
mutant int-parse-boxed-value prims/int_parse.render src/primitive_core.cc "Cannot prove" "-prover z3v4.5" \
  "Object* parsed = Primitive::integer(value, process);" "Object* parsed = Primitive::integer(0, process);"
entry crc                   pass "" prims/crc.gen.c -prover z3v4.5
mutant crc-table-length prims/crc.render src/primitive_core.cc "Cannot prove|o_len" "-prover z3v4.5" \
  "if (table->length() != 0x100) FAIL(INVALID_ARGUMENT);" "if (table->length() != 0xff) FAIL(INVALID_ARGUMENT);"
mutant crc-shift-count prims/crc.render src/primitive_core.cc "shift|Cannot prove" "-prover z3v4.5" \
  "if ((width != 0 && width < 8) || width > 64)" "if ((width != 0 && width < 8) || width > 80)"
# A modular uint64 left shift still requires a valid literal count.
mutant crc-literal-shift prims/crc.render src/primitive_core.cc "Shifting by an amount" "-prover z3v4.5" \
  "big_endian ? checksum << 8 : checksum >> 8" "big_endian ? checksum << 64 : checksum >> 8"
entry argument-error        pass "" prims/argument_error.gen.c
mutant argument-error-type prims/argument_error.render src/primitive.cc "Cannot prove condition" "" \
  "Primitive::return_not_a_smi(Process* process, Object* value)@@FAIL(OUT_OF_RANGE);" "FAIL(WRONG_OBJECT_TYPE);"
entry blob-validation       pass "" prims/blob_validation.gen.c -allow_dead_code -prover z3v4.5
mutant blob-validation-end prims/blob_validation.render src/primitive_core.cc "uchars_split|Cannot prove condition" "-allow_dead_code -prover z3v4.5" \
  "PRIMITIVE(byte_array_is_valid_string_content)@@end <= bytes.length()" "true"
mutant blob-validation-convert-utf8 prims/blob_validation.render src/primitive_core.cc "Cannot prove" "-allow_dead_code -prover z3v4.5" \
  "PRIMITIVE(byte_array_convert_to_string)@@  if (!valid) FAIL(ILLEGAL_UTF_8);" ""
mutant blob-validation-convert-length prims/blob_validation.render src/primitive_core.cc "Cannot prove|No matching" "-allow_dead_code -prover z3v4.5" \
  "char_cast(bytes.address()) + start, end - start);" "char_cast(bytes.address()) + start, end);"
mutant blob-validation-utf16-capacity prims/blob_validation.render src/primitive_core.cc "No matching heap chunks: ushorts_" "-allow_dead_code -prover z3v4.5" \
  "output->length() / static_cast<word>(sizeof(uint16))" "output->length()"
mutant blob-validation-utf16-short-write prims/blob_validation.render src/primitive_core.cc "Cannot prove .*written .*blob_len" "-allow_dead_code -prover z3v4.5" \
  "  if (written != utf_16_length) FAIL(INVALID_ARGUMENT);" ""
mutant blob-validation-utf16-alignment prims/blob_validation.render src/primitive_core.cc "Cannot prove .*mod .*dst" "-allow_dead_code -prover z3v4.5" \
  "  if (reinterpret_cast<uword>(output->address()) % sizeof(uint16) != 0) return -1;" ""
mutant blob-validation-to-string-length prims/blob_validation.render src/primitive_core.cc "ILP32:Cannot prove" "-allow_dead_code -prover z3v4.5" \
  "  if (utf_8_length > Smi::MAX_SMI_VALUE) FAIL(OUT_OF_BOUNDS);" ""
mutant blob-validation-to-string-write prims/blob_validation.render src/primitive_core.cc "Cannot prove" "-allow_dead_code -prover z3v4.5" \
  "  if (!filled) FAIL(INVALID_ARGUMENT);" ""
entry platform-names        pass "" prims/platform.gen.c -prover z3v4.5
mutant platform-names-provider prims/platform.render src/primitive_core.cc "Cannot prove" "-prover z3v4.5" \
  "const char* platform_name = OS::get_platform();" "const char* platform_name = OS::get_architecture();"
mutant platform-names-alloc-error model/objects.render src/process.cc "Cannot prove|No matching" "-prover z3v4.5" \
  "if (result == null) return Error::from(program()->allocation_failed());" "if (result == null) return result;"
mutant platform-names-copy model/objects.render src/process.cc "Cannot prove|No matching" "" \
  "String* Process::allocate_string(const char* content, word length)@@  bytes._initialize(content);" ""
entry heap-limits           pass "" heap/limits.gen.c -prover z3v4.5
mutant heap-limits-mutable-range heap/limits.render src/third_party/dartino/object_memory.cc "RENDER:the linked-list range is not a variable or member" "" \
  "uword Space::size() const@@for (auto chunk : chunk_list_)" "for (auto chunk : const_cast<Space*>(this)->chunk_list_)"
mutant heap-limits-chunk-size heap/limits.render src/third_party/dartino/object_memory.cc "Cannot prove" "-prover z3v4.5" \
  "result += chunk->size();" "result += chunk->size() / 2;"
mutant heap-limits-spaces heap/limits.render src/third_party/dartino/two_space_heap.h "Cannot prove" "-prover z3v4.5" \
  "old_space_.size() + new_space()->size()" "old_space_.size() + old_space_.size()"
mutant heap-limits-sum heap/limits.render src/heap.cc "Potential arithmetic overflow" "-prover z3v4.5" \
  "if (external > UINTPTR_MAX - internal) return UINTPTR_MAX;" ""
mutant heap-limits-double heap/limits.render src/heap.cc "Potential arithmetic overflow" "-prover z3v4.5" \
  "if (bytes > INTPTR_MAX / 2) return INTPTR_MAX;" ""
mutant heap-limits-cap heap/limits.render src/heap.cc "Cannot prove .*growth_limit" "-prover z3v4.5" \
  "if (next > max_heap_size_) next = max_heap_size_;" ""
mutant heap-limits-tight heap/limits.render src/heap.cc "Cannot prove .*allocation_room" "-prover z3v4.5" \
  "total > static_cast<uword>(limit_)" "total >= static_cast<uword>(limit_)"
mutant heap-limits-promote heap/limits.render src/heap.cc "Cannot prove true == .*failed" "-prover z3v4.5" \
  "total > static_cast<uword>(pending_limit_)" "total >= static_cast<uword>(pending_limit_)"
mutant heap-limits-negative heap/limits.render src/process.h "Cannot prove .*allocation_room" "-prover z3v4.5" \
  "size >= 0 && size <= max" "size <= max"
mutant heap-limits-status heap/limits.render src/process.h "Cannot prove 1 ==" "-prover z3v4.5" \
  "result ? ObjectHeap::ALLOCATION_SUCCESS : ObjectHeap::ALLOCATION_HIT_LIMIT" "result ? ObjectHeap::ALLOCATION_HIT_LIMIT : ObjectHeap::ALLOCATION_SUCCESS"
entry gc-count              pass "" prims/gc_count.gen.c -allow_dead_code -prover z3v4.5
mutant gc-count-wrap prims/gc_count.render src/heap.cc "Cannot prove|No matching|overflow" "-allow_dead_code -prover z3v4.5" \
  "  if (count == limit) return 0;" ""
mutant gc-count-full prims/gc_count.render src/heap.cc "Cannot prove|No matching|overflow" "-allow_dead_code -prover z3v4.5" \
  "if (type != NEW_SPACE_GC) full_gc_count_" "if (type == FULL_GC) full_gc_count_"
mutant gc-count-select prims/gc_count.render src/primitive_core.cc "Cannot prove|No matching|overflow" "-allow_dead_code -prover z3v4.5" \
  "return Smi::from(process->gc_count(NEW_SPACE_GC));" "return Smi::from(process->gc_count(FULL_GC));"
entry process-ids           pass "" prims/process_ids.gen.c -prover z3v4.5
mutant process-ids-exhausted prims/process_ids.render src/scheduler.cc "Cannot prove|No matching|overflow" "-prover z3v4.5" \
  "if (id == INVALID_PROCESS_ID) return id;" ""
mutant process-ids-limit prims/process_ids.render src/scheduler.cc "Cannot prove|No matching|overflow" "-prover z3v4.5" \
  "next <= INT32_MAX && Smi::is_valid(next)" "next <= INT32_MAX || Smi::is_valid(next)"
mutant process-ids-current prims/process_ids.render src/primitive_core.cc "Cannot prove|No matching|overflow" "-prover z3v4.5" \
  "return Smi::from(process->id());" "return Smi::from(0);"
mutant process-ids-boot prims/process_ids.render src/scheduler.cc "Cannot prove|No matching|overflow" "-prover z3v4.5" \
  "return boot_process_ ? boot_process_->id() : INVALID_PROCESS_ID;" "return boot_process_ ? boot_process_->id() : 0;"
entry spawn-method pass "" prims/spawn_method.gen.c -prover z3v4.5
mutant spawn-method-search prims/spawn_method.render src/v2_method_table.cc "Cannot prove|decreases" "-prover z3v4.5" \
  "word V2MethodTable::index_of_entry@@      low = mid + 1;" "      low = mid;"
mutant spawn-method-missing prims/spawn_method.render src/v2_method_table.cc "Cannot prove" "-prover z3v4.5" \
  "word V2MethodTable::index_of_entry@@  return -1;" "  return 0;"
mutant spawn-method-tag prims/spawn_method.render src/program.h "Cannot prove" "-prover z3v4.5" \
  "bytecodes.data()[3] == '2'" "bytecodes.data()[3] == '1'"
mutant spawn-method-legacy prims/spawn_method.render src/primitive_core.cc "Cannot prove" "-prover z3v4.5" \
  "PRIMITIVE(spawn_method)@@      : -1;" "      : 0;"
entry word-size             pass "" prims/word_size.gen.c
mutant word-size-bits prims/word_size.render src/primitive_core.cc "smi_val|Cannot prove condition" "" \
  "return Smi::from(WORD_SIZE);" "return Smi::from(WORD_SIZE * 8);"

# bitmap byte_zap. `-allow_dead_code`: on ILP32 the int argument's round
# trip check is dead (int is a word).
entry blit-pixel-memory pass "" prims/blit_pixel.gen.c -prover z3v4.5
mutant blit-pixel-memory-wide prims/blit_pixel.render src/primitive_bitmap.cc "Cannot prove|No matching|overflow|array chunk" "-prover z3v4.5" \
  "dest[dest_index + 1] = value / 256;" "dest[dest_index + 2] = value / 256;"
mutant blit-entry-lookup prims/blit.render src/primitive_bitmap.cc "Cannot prove|No matching" "-allow_dead_code -prover redux" \
  "blob.length() < 0x100" "blob.length() < 0xff"
mutant blit-entry-cpu-budget prims/blit.render src/primitive_policy.h "Cannot prove" "-allow_dead_code -prover redux" \
  "return max_run_time_us > 0 || cpu_budget_us > 0;" "return max_run_time_us > 0;"
spawn entry_run LP64 blit-rows pass "" prims/blit.gen.c -prover redux
# Every nonnegative ILP32 length fits the fast quota calculation.
defer entry_run ILP32 blit-rows pass "" prims/blit.gen.c -allow_dead_code -prover redux
mutant blit-quota-width prims/blit.render src/primitive_bitmap.cc "ILP32:overflow" "-prover redux" \
  "static_cast<int64>(src_length) + dest_length" "src_length + dest_length"
mutant blit-quota-check prims/blit.render src/primitive_bitmap.cc "Cannot prove|No matching" "-prover redux" \
  "lines) * pixels <= budget" "lines) * pixels < budget"
mutant blit-large-budget prims/blit.render src/primitive_bitmap.cc "LP64:Cannot prove" "-allow_dead_code -prover redux" \
  "remaining_lines <= remainder_budget / pixels;" "remaining_lines < remainder_budget / pixels;"
mutant blit-wide-bound prims/blit.render src/primitive_bitmap.cc "Cannot prove|No matching" "-prover redux" \
  "word extra = operation == ADD_16_LE ? 1 : 0;" "word extra = 0;"
mutant blit-row-index prims/blit.render src/primitive_bitmap.cc "Cannot prove|overflow|No matching" "-prover redux" \
  "row * src_line_stride;" "(row + 1) * src_line_stride;"
entry byte-zap              pass "" prims/byte_zap.gen.c -allow_dead_code -prover z3v4.5
# One byte past the destination: the memset fails.
mutant byte-zap-past-end prims/byte_zap.render src/primitive_bitmap.cc "uchars|No matching" "-allow_dead_code -prover z3v4.5" \
  "  memset(bytes.address(), value, bytes.length());" "  memset(bytes.address(), value, bytes.length() + 1);"

# time_info and its calendar (red-team round 4). `-allow_dead_code`: the
# time_t round trip check of os_localtime is dead on LP64; UNREACHABLE.
TI_OPTS="-allow_dead_code -prover z3v4.5"
entry local-epoch pass "" prims/local_epoch.gen.c -prover z3v4.5
mutant local-epoch-sentinel prims/local_epoch.render src/primitive_core.cc "Cannot prove|No matching" "-prover z3v4.5" \
  "result == -1 && decomposed.tm_wday == -1" "result == -1"
mutant local-epoch-year prims/local_epoch.render src/primitive_core.cc "overflow|underflow|Cannot prove|No matching" "-prover z3v4.5" \
  "tm_year += 0x100000000LL" "tm_year += 0xffffffffLL"
mutant local-epoch-dst prims/local_epoch.render src/primitive_core.cc "Cannot prove|No matching" "-prover z3v4.5" \
  "decomposed.tm_isdst = -1;" "decomposed.tm_isdst = 1;"
mutant local-epoch-weekday prims/local_epoch.render src/primitive_core.cc "Cannot prove" "-prover z3v4.5" \
  "decomposed.tm_wday = -1;" "decomposed.tm_wday = 0;"
entry time-info             pass "" prims/time_info.gen.c -allow_dead_code -prover z3v4.5
# The fix reverted: `days * SECONDS_PER_DAY` overflows near INT64_MIN.
mutant time-info-seconds-of-day prims/time_info.render src/primitive_core.cc "overflow|underflow" "$TI_OPTS" \
  "int seconds_of_day = static_cast<int>(floor_mod(timestamp, SECONDS_PER_DAY));" "int seconds_of_day = static_cast<int>(timestamp - days * SECONDS_PER_DAY);"
# local_fields without its year check: the shift into the equivalent year
# overflows (the year is unbounded).
mutant time-info-local-year prims/time_info.render src/primitive_core.cc "overflow|underflow|1000000000000000" "$TI_OPTS" \
  "  if (!Smi::is_valid32(utc.year)) return false;\n" "" \
  "  if (!Smi::is_valid32(utc.year)) /*@ open tm_fields(&tm); @*/ return false;\n" ""
# The primitive without its year check: the year is not a smi (on ILP32
# not even a word: the conversion fails first).
mutant time-info-year-smi prims/time_info.render src/primitive_core.cc "smi_range|overflow|underflow" "$TI_OPTS" \
  "  if (!Smi::is_valid32(fields.year)) FAIL(OUT_OF_RANGE);\n" ""

# The MutableBlob decoding. `-allow_dead_code`: the check `content == null`
# (README, "Findings") is dead, VeriFast proves it.
entry mutable-byte-content  pass "" blob/mutable_byte_content.gen.c -allow_dead_code -prover z3v4.5
# 357d1127 reverted in mutable_byte_content: the recursive call fails.
mutant mutable-byte-content-357d1127 blob/mutable_byte_content.render src/objects_runtime.cc "depth" "-allow_dead_code -prover z3v4.5" \
  "  if (depth >= MAX_BYTE_CONTENT_DEPTH) return false;\n" ""
# Without the program-heap check a read-only object is written.
mutant mutable-byte-content-program-heap blob/mutable_byte_content.render src/objects_runtime.cc "in_program_heap|mutable_result" "-allow_dead_code -prover z3v4.5" \
  "  if (is_heap_object(this) && HeapObject::cast(this)->on_program_heap(process)) {" "  if (false) {"
# Without the external tag check a proxy's struct is handed out as bytes
# (both decoders).
mutant mutable-byte-content-external-tag blob/mutable_byte_content.render src/objects_runtime.cc "blob_ok|mutable_result|external_bytes|uchars" "-allow_dead_code -prover z3v4.5" \
  "    if (byte_array->has_external_address() && byte_array->external_tag() != RawByteTag) return false;\n    ByteArray::Bytes bytes" "    ByteArray::Bytes bytes"
mutant byte-content-external-tag blob/byte_content.render src/objects.cc "blob_ok|blob_result|external_bytes|uchars" "" \
  "    if (byte_array->has_external_address() && byte_array->external_tag() != RawByteTag) return false;\n    ByteArray::ConstBytes bytes" "    ByteArray::ConstBytes bytes"

# 5. The Rust side (VeriFast's Rust front end, host target only).

rust_entry_run() {
  local failures=0
  local name="$1" expect="$2" file="$3"
  [[ -n "$filter" && "$name" != *"$filter"* ]] && return
  if [ ! -d "$ACXX_HOME/tools/rustup" ]; then
    printf 'SKIP  %-40s no VeriFast Rust toolchain\n' "$name"
    return
  fi
  local out status verdict=pass
  out=$(RUSTUP_HOME="$ACXX_HOME/tools/rustup" CARGO_HOME="$ACXX_HOME/tools/cargo" "$VERIFAST" -allow_dead_code "$file" 2>&1)
  status=$?
  [ $status -ne 0 ] && verdict=fail
  local first
  first=$(echo "$out" | grep -m1 -E "error|errors found" || true)
  if [ "$verdict" = "$expect" ]; then
    printf 'ok    %-40s %s: %s\n' "$name" "$verdict" "$first"
  else
    printf 'FAIL  %-40s %s (expected %s): %s\n' "$name" "$verdict" "$expect" "$first"
    failures=$((failures + 1))
  fi
  return $failures
}
# (One job: the Rust front end builds in one cargo directory.)
rust_entries() {
  local f=0
  rust_entry_run rust-view pass rust/view_accessors.rs || f=$((f + $?))
  sed 's|internal_string(obj, ?len) \&\*\& i < len;|internal_string(obj, ?len) \&*\& i <= len;|' \
    rust/view_accessors.rs > "$ACXX_WORK/logs/view_accessors_neg.rs"
  rust_entry_run rust-view-index-at-length fail "$ACXX_WORK/logs/view_accessors_neg.rs" || f=$((f + $?))
  # The like-for-like trial (README, "The Rust raw-memory layer"): of the
  # five accessors, class_id and class_tag stop VeriFast's Rust front end
  # ("Todo: BinOp::Shr"); the other three verify.
  sed '/pub unsafe fn class_id/,/^    }$/d' rust/view_trial.rs | sed '/pub unsafe fn class_tag/,/^    }$/d' \
    > "$ACXX_WORK/logs/view_trial_noshift.rs"
  rust_entry_run rust-trial-three pass "$ACXX_WORK/logs/view_trial_noshift.rs" || f=$((f + $?))
  return $f
}
# The same five in Verus, with vstd::raw_ptr permissions.
verus_trial() {
  [[ -n "$filter" && "verus-trial" != *"$filter"* ]] && return 0
  if ! command -v verus > /dev/null; then
    printf 'SKIP  %-40s no verus\n' verus-trial
    return 0
  fi
  local out
  out=$(cd rust && verus --crate-type=lib verus_pptr.rs 2>&1)
  if echo "$out" | grep -q "verification results:: [0-9]* verified, 0 errors"; then
    printf 'ok    %-40s pass: %s\n' verus-trial "$(echo "$out" | grep 'verification results')"
    return 0
  fi
  printf 'FAIL  %-40s %s\n' verus-trial "$(echo "$out" | grep -m1 -E 'error|verification results')"
  return 1
}
spawn verus_trial
spawn rust_entries

# The second phase.
render_status=0
if [ -n "$render_pid" ]; then
  wait "$render_pid"
  render_status=$?
fi
for d in "${deferred[@]}"; do
  eval "spawn $d"
done

for i in "${!pids[@]}"; do
  if [ "${pids[$i]}" = "$render_pid" ]; then
    s=$render_status
  else
    wait "${pids[$i]}"
    s=$?
  fi
  [ $s -ne 0 ] && failures=$((failures + s))
  cat "$JOBS/$i.log"
done
echo "failures: $failures"
exit $((failures > 0))
