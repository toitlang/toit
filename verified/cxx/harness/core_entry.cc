// Copyright (C) 2026 Toit contributors.

#include "prelude.h"
#define private public
#define protected public
#include "interpreter.h"
#include "interpreter_v2.h"
#include "objects_inline.h"
#include "process_group.h"
#undef protected
#undef private
#include "heap.cc"
#include "v2_method_table.cc"
#include "interpreter_v2.cc"

using namespace toit;

extern Process child;
extern Interpreter interpreter;
extern ProcessGroup group;
extern Program image;
extern PrimitivePolicy sandbox_policy;
GcMetadata GcMetadata::singleton_;
static uword initial_epoch;
static bool accepted, called, switch_task;
static Task* next_task;
static int64 result_value;
static uint8 arities[] = {1, 0};
static uint8 bytecodes[] = {'T', 'B', 'C', '2', 0};
static uint32 records[] = {0};
static Object* globals[2];

// Construct the already-admitted process with an immutable policy pointer.
// Process admission and initial task allocation have separate proof targets.
Process::Process(ProcessRunner*, ProcessGroup* owner, SystemMessage*)
    : id_(1), program_(&image), group_(owner), policy_(&sandbox_policy),
      entry_(Method::invalid()), spawn_method_(Method::invalid()),
      object_heap_(&image, this, nullptr, nullptr, nullptr) {}

// Debug validation is disabled in this entry-point check.
extern "C" char* getenv(const char*) { return nullptr; }

void toit::fail(const char*, ...) {
  CXXV_ASSERT(!V2MethodTable::checked_loop_linked() && !accepted && !called,
              "only a rejected table with no checked loop stops before core entry");
  exit(0);
}

extern "C" uword toit_v2_run(toit_v2_context* ctx) {
  CXXV_ASSERT(!called, "enter the core once");
  called = true;
  CXXV_ASSERT(ctx->process == &child && ctx->watermark == &interpreter.watermark_,
              "pass the running process and its interpreter watermark");
  CXXV_ASSERT(ctx->accepted == (accepted ? TOIT_V2_ACCEPTED : 0) && ctx->unchecked == 0 &&
              (accepted || V2MethodTable::checked_loop_linked()),
              "untrusted execution uses only the admitted verified or checked loop");
  CXXV_ASSERT(ctx->core_arities == sandbox_policy.core_arities_ &&
              ctx->core_arities_length == (sandbox_policy.core_arities_ == nullptr ? 0 : sizeof(arities)),
              "expose the active policy's primitive arities");
  CXXV_ASSERT(ctx->program.bytecodes == bytecodes && ctx->program.bytecodes_length == sizeof(bytecodes) &&
              ctx->program.methods == records && ctx->program.methods_length == 1 &&
              ctx->program.globals == reinterpret_cast<uword*>(globals) && ctx->program.globals_length == 2,
              "hand over bytecodes, method records and mutable process globals with their extents");
  auto* heap = child.object_heap();
  auto* space = &heap->two_space_heap_.semi_space_;
  CXXV_ASSERT(ctx->epoch == &heap->v2_epoch_ && *ctx->epoch == initial_epoch &&
              ctx->new_space_top == &space->top_ && ctx->new_space_limit == &space->limit_,
              "the core observes this process's epoch and allocation window in place");
  CXXV_ASSERT(!heap->retrying_primitive() && interpreter.preemption_method_header_bcp_ == nullptr,
              "clear the retry and profiler state before core entry");
  if (switch_task) heap->set_task(next_task);
  CXXV_ASSERT(*ctx->epoch == initial_epoch + static_cast<uword>(switch_task),
              "the supplied epoch address observes a native task switch, including wraparound");
  ctx->result_state = Interpreter::Result::YIELDED;
  ctx->result_value = result_value;
  return 0;
}

int main() {
  static_assert(WORD_BIT_SIZE == CXXV_WORD_BITS, "target word width");
  sandbox_policy.kind_ = PrimitivePolicy::UNTRUSTED;
  sandbox_policy.core_arities_ = nondet_bool() ? arities : nullptr;
  sandbox_policy.core_arities_length_ = sizeof(arities);
  new (&child) Process(nullptr, &group, nullptr);
  interpreter.process_ = &child;
  interpreter.watermark_.store(nullptr);
  image.header_.size_in_pages_ = 1;
  image.bytecodes = List<uint8>(bytecodes, sizeof(bytecodes));
  image.global_variables.length_ = 2;
  V2MethodTable table(records, 1, bytecodes, sizeof(bytecodes), false);
  unsigned verification = nondet_uint() % 3;
  if (verification != 0) table.mark_verified(verification == 2);
  accepted = verification == 1;
  group.v2_methods_ = &table;

  auto* heap = child.object_heap();
  heap->global_variables_ = globals;
  heap->retrying_primitive_ = true;
  heap->limit_ = heap->pending_limit_ = 0;
  initial_epoch = heap->v2_epoch_ = nondet_ulong();
  constexpr unsigned stride = GcMetadata::CARD_SIZE / WORD_SIZE;
  uword stacks[2 * stride] = {};
  stacks[0] = stacks[stride] = 2 * STACK_TAG;
  Object* tasks[] = {nullptr, HeapObject::from_address(reinterpret_cast<uword>(stacks)), Smi::zero(),
                     nullptr, HeapObject::from_address(reinterpret_cast<uword>(stacks + stride)), Smi::one()};
  auto* first = static_cast<Task*>(HeapObject::from_address(reinterpret_cast<uword>(tasks)));
  next_task = static_cast<Task*>(HeapObject::from_address(reinterpret_cast<uword>(tasks + 3)));
  first->_set_header(Smi::zero(), TASK_TAG);
  next_task->_set_header(Smi::zero(), TASK_TAG);
  heap->task_ = first;
  uint8 cards[2] = {};
  GcMetadata::singleton_.remembered_set_bias_ = reinterpret_cast<uword>(cards) -
      (reinterpret_cast<uword>(tasks[1]) >> GcMetadata::CARD_SIZE_LOG_2);
  switch_task = nondet_bool();
  result_value = nondet_int64();
  auto result = interpreter.run_v2();
  CXXV_ASSERT(called && result.state() == Interpreter::Result::YIELDED && result.value() == result_value,
              "return the result produced by the core");
  CXXV_ASSERT(cards[switch_task] == GcMetadata::NEW_SPACE_POINTERS && cards[!switch_task] == 0,
              "remember the stack of the task running when the core returns");
}
