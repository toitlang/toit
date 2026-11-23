// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The retry protocol of the C++ primitives (verified/CONTRACTS.toml,
// [[prim_retry]]; verified/cxx/annotated/README.md, "The retry obligation").
//
// When a primitive fails for want of memory (MALLOC_FAILED,
// ALLOCATION_FAILED, CROSS_PROCESS_GC), the interpreter collects garbage and
// calls it again, and the verified core takes the whole sequence as ONE
// step. That is sound only if the failed call had no visible effect: no
// existing object written, no message sent or consumed, no resource,
// finalizer or timer registered, no malloced memory kept or freed.
//
// The test makes every allocation of a call fail in turn: the k-th
// allocation (heap or malloc) and all after it, for every k up to the
// number a successful call makes. TwoSpaceHeap::allocate (every heap object)
// and malloc/calloc/realloc/free (every malloc of the VM, `new` included:
// libstdc++ is linked statically) are wrapped by the linker (--wrap, see
// CMakeLists.txt). For each failure that the primitive reports as an
// out-of-memory error it checks that
//   1. the arguments (deeply: fields, elements, bytes, finalizer bits) and
//      the process's state (mailbox, arguments, timers, resource groups,
//      object notifiers, external memory) are what they were before the
//      call, no malloced block of the call survives and no block from before
//      the call was freed;
//   2. the retry (the same call, allocation working again) gives the result,
//      arguments, process state and malloc balance of a call that never
//      failed.
// A primitive that handles a failure itself (any other result) is not
// checked further for that k.

#if defined(__linux__)

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <functional>
#include <map>
#include <string>
#include <vector>

#include "../../src/top.h"

// The test reads private state of the process and the heap (counters
// without accessors).
#define private public
#define protected public
#include "../../src/compiler/compiler.h"
#include "../../src/event_sources/timer.h"
#include "../../src/flags.h"
#include "../../src/flash_registry.h"
#include "../../src/heap.h"
#include "../../src/messaging.h"
#include "../../src/objects_inline.h"
#include "../../src/os.h"
#include "../../src/primitive.h"
#include "../../src/process.h"
#include "../../src/process_group.h"
#include "../../src/resource.h"
#include "../../src/scheduler.h"
#include "../../src/snapshot.h"
#include "../../src/vm.h"
#undef private
#undef protected

// ---------------------------------------------------------------------------
// Allocation failure injection.

namespace {

bool armed = false;          // Only allocations of the primitive's call count.
int events = 0;              // Allocations of the call so far.
int fail_from = -1;          // Allocations with index >= fail_from fail.
const int MAX_LIVE = 4096;
void* live[MAX_LIVE];        // Blocks malloced by the call and not freed.
int live_count = 0;
int foreign_frees = 0;       // Frees by the call of blocks from before it.

bool inject() {
  if (!armed) return false;
  int event = events++;
  return fail_from >= 0 && event >= fail_from;
}

void note_alloc(void* p) {
  if (!armed || p == null) return;
  if (live_count == MAX_LIVE) abort();
  live[live_count++] = p;
}

void note_free(void* p) {
  if (!armed || p == null) return;
  for (int i = 0; i < live_count; i++) {
    if (live[i] == p) {
      live[i] = live[--live_count];
      return;
    }
  }
  foreign_frees++;
}

}  // namespace

#if __SIZEOF_POINTER__ == 8
#define HEAP_ALLOCATE(prefix) prefix##_ZN4toit12TwoSpaceHeap8allocateEm
#else
#define HEAP_ALLOCATE(prefix) prefix##_ZN4toit12TwoSpaceHeap8allocateEj
#endif

extern "C" {
void* __real_malloc(size_t size);
void* __real_calloc(size_t count, size_t size);
void* __real_realloc(void* pointer, size_t size);
void __real_free(void* pointer);
void* HEAP_ALLOCATE(__real_)(void* self, uintptr_t size);

void* __wrap_malloc(size_t size) {
  if (inject()) return null;
  void* result = __real_malloc(size);
  note_alloc(result);
  return result;
}

void* __wrap_calloc(size_t count, size_t size) {
  if (inject()) return null;
  void* result = __real_calloc(count, size);
  note_alloc(result);
  return result;
}

void* __wrap_realloc(void* pointer, size_t size) {
  if (inject()) return null;
  void* result = __real_realloc(pointer, size);
  if (result != null) {
    note_free(pointer);
    note_alloc(result);
  }
  return result;
}

void __wrap_free(void* pointer) {
  note_free(pointer);
  __real_free(pointer);
}

void* HEAP_ALLOCATE(__wrap_)(void* self, uintptr_t size) {
  if (inject()) return null;
  return HEAP_ALLOCATE(__real_)(self, size);
}
}

namespace toit {

#define MODULE_INDEX(name, entry) MODULE_INDEX_##name,
enum { MODULES(MODULE_INDEX) };
#undef MODULE_INDEX

#define CORE_INDEX(name, arity) CORE_##name,
enum { MODULE_CORE(CORE_INDEX) };
#undef CORE_INDEX
#define BITMAP_INDEX(name, arity) BITMAP_##name,
enum { MODULE_BITMAP(BITMAP_INDEX) };
#undef BITMAP_INDEX
#define TIMER_INDEX(name, arity) TIMER_##name,
enum { MODULE_TIMER(TIMER_INDEX) };
#undef TIMER_INDEX
#define EVENTS_INDEX(name, arity) EVENTS_##name,
enum { MODULE_EVENTS(EVENTS_INDEX) };
#undef EVENTS_INDEX

typedef Object* (*PrimitiveFunction)(Process* process, Object** args);

static Program* program = null;
static ProcessGroup* group = null;

// ---------------------------------------------------------------------------
// Processes and arguments.

static Process* new_process() {
  InitialMemoryManager manager;
  if (!manager.allocate()) FATAL("no memory");
  manager.global_variables = program->global_variables.copy();
  Process* process = _new Process(program, group, null, &manager);
  // No allocation limit (a new heap's limit refuses external memory until
  // the first GC, which this test never runs): only the injected failures
  // fail.
  process->object_heap()->limit_ = process->object_heap()->max_heap_size_;
  return process;
}

static void delete_process(Process* process) {
  group->begin_process_teardown(process);
  delete process;
  group->finish_process_teardown();
}

static Object* check(Object* object) {
  if (object == null) FATAL("allocation failed while building arguments");
  return object;
}

static Object* smi(word value) { return Smi::from(value); }

static Object* dbl(Process* process, double value) {
  return check(process->object_heap()->allocate_double(value));
}

static Object* big(Process* process, int64 value) {
  return check(process->object_heap()->allocate_large_integer(value));
}

static Object* str(Process* process, const char* value) {
  return check(process->allocate_string(value));
}

static ByteArray* bytes(Process* process, word length, bool external = false) {
  ByteArray* result = process->allocate_byte_array(length, external);
  check(result);
  ByteArray::Bytes content(result);
  for (word i = 0; i < length; i++) content.address()[i] = static_cast<uint8>(i * 7 + 1);
  return result;
}

static Instance* instance(Process* process, Smi* class_id) {
  return Instance::cast(check(process->object_heap()->allocate_instance(class_id)));
}

static Array* array(Process* process, word length, Object* filler) {
  return Array::cast(check(process->object_heap()->allocate_array(length, filler)));
}

// A copy-on-write byte array over a read-only (not yet copied) backing.
static Object* cow(Process* process, word length) {
  Instance* result = instance(process, program->byte_array_cow_class_id());
  result->at_put(Instance::BYTE_ARRAY_COW_BACKING_INDEX, bytes(process, length));
  result->at_put(Instance::BYTE_ARRAY_COW_IS_MUTABLE_INDEX, process->false_object());
  return result;
}

static Object* list(Process* process, word length, word capacity) {
  Instance* result = instance(process, program->list_class_id());
  result->at_put(Instance::LIST_ARRAY_INDEX, array(process, capacity, smi(0)));
  result->at_put(Instance::LIST_SIZE_INDEX, smi(length));
  return result;
}

static PrimitiveFunction lookup(int module, int index) {
  const PrimitiveEntry* entry = Primitive::at(module, index);
  if (entry == null || entry->function == null) FATAL("no primitive %d/%d", module, index);
  return reinterpret_cast<PrimitiveFunction>(entry->function);
}

// Calls a primitive with its arguments in order (ARGS reads __args[0],
// __args[-1], ...: the first argument at the highest address).
static Object* call(Process* process, int module, int index, const std::vector<Object*>& args) {
  Object* slots[16];
  word n = args.size();
  if (n > 16) FATAL("too many arguments");
  for (word i = 0; i < n; i++) slots[n - 1 - i] = args[i];
  Object* dummy[1] = { null };
  Object** pointer = n == 0 ? &dummy[0] : &slots[n - 1];
  return lookup(module, index)(process, pointer);
}

// ---------------------------------------------------------------------------
// Observable state.

static void hex(std::string* out, const uint8* data, word length) {
  char buffer[4];
  uint32 hash = 2166136261u;
  for (word i = 0; i < length; i++) {
    hash = (hash ^ data[i]) * 16777619u;
    if (i < 32) {
      snprintf(buffer, sizeof(buffer), "%02x", data[i]);
      *out += buffer;
    }
  }
  snprintf(buffer, sizeof(buffer), "#");
  *out += buffer;
  *out += std::to_string(hash);
}

static void dump(Process* process, Object* object, std::string* out, std::map<HeapObject*, int>* seen) {
  if (is_smi(object)) {
    *out += "s" + std::to_string(Smi::value(object));
    return;
  }
  if (Primitive::is_error(object)) {
    Object* value = Primitive::unmark_from_error(program, object);
    *out += "E(";
    dump(process, value, out, seen);
    *out += ")";
    return;
  }
  HeapObject* heap_object = HeapObject::cast(object);
  if (heap_object->on_program_heap(process)) {
    // Program objects are shared and never change; their identity is
    // the same in every run.
    char buffer[32];
    snprintf(buffer, sizeof(buffer), "P%p", static_cast<void*>(heap_object));
    *out += buffer;
    return;
  }
  auto it = seen->find(heap_object);
  if (it != seen->end()) {
    *out += "@" + std::to_string(it->second);
    return;
  }
  int id = seen->size();
  (*seen)[heap_object] = id;
  if (heap_object->has_active_finalizer()) *out += "F";
  switch (heap_object->class_tag()) {
    case ARRAY_TAG: {
      Array* a = Array::cast(heap_object);
      *out += "[";
      for (word i = 0; i < a->length(); i++) {
        dump(process, a->at(i), out, seen);
        *out += ",";
      }
      *out += "]";
      break;
    }
    case BYTE_ARRAY_TAG: {
      ByteArray* b = ByteArray::cast(heap_object);
      if (b->has_external_address() && b->external_tag() != RawByteTag) {
        *out += "proxy" + std::to_string(b->external_tag());
        *out += b->as_external() == null ? "-" : "+";
        break;
      }
      ByteArray::Bytes content(b);
      *out += b->has_external_address() ? "B" : "b";
      *out += std::to_string(content.length()) + ":";
      if (content.address() != null) hex(out, content.address(), content.length());
      break;
    }
    case STRING_TAG: {
      String* s = String::cast(heap_object);
      String::Bytes content(s);
      *out += "S" + std::to_string(content.length()) + ":";
      hex(out, content.address(), content.length());
      *out += "h" + std::to_string(s->_raw_hash_code());
      break;
    }
    case DOUBLE_TAG: {
      char buffer[32];
      snprintf(buffer, sizeof(buffer), "d%a", Double::cast(heap_object)->value());
      *out += buffer;
      break;
    }
    case LARGE_INTEGER_TAG:
      *out += "L" + std::to_string(LargeInteger::cast(heap_object)->value());
      break;
    case INSTANCE_TAG: {
      Instance* i = Instance::cast(heap_object);
      *out += "I" + std::to_string(Smi::value(i->class_id())) + "{";
      word fields = Instance::fields_from_size(i->size(program));
      for (word f = 0; f < fields; f++) {
        dump(process, i->at(f), out, seen);
        *out += ",";
      }
      *out += "}";
      break;
    }
    default:
      *out += "tag" + std::to_string(heap_object->class_tag());
  }
}

static std::string dump_values(Process* process, const std::vector<Object*>& values) {
  std::string out;
  std::map<HeapObject*, int> seen;
  for (auto value : values) {
    dump(process, value, &out, &seen);
    out += ";";
  }
  return out;
}

static std::string process_state(Process* process) {
  std::string out;
  out += "messages=" + std::to_string(process->message_count());
  Message* first = process->peek_message();
  if (first != null && first->is_system()) {
    char buffer[64];
    snprintf(buffer, sizeof(buffer), " first=%p data=%p", static_cast<void*>(first),
             static_cast<void*>(static_cast<SystemMessage*>(first)->data()));
    out += buffer;
  }
  out += " mailbox=" + std::to_string(process->mailbox_count_) + "/" + std::to_string(process->mailbox_bytes_);
  out += " main_args=" + std::to_string(process->main_arguments() != null);
  out += " spawn_args=" + std::to_string(process->spawn_arguments() != null);
  out += " timers=" + std::to_string(process->timer_count_);
  int groups = 0;
  for (auto it : process->resource_groups_) { USE(it); groups++; }
  out += " groups=" + std::to_string(groups);
  int notifiers = 0;
  for (auto it : process->object_heap()->object_notifiers_) { USE(it); notifiers++; }
  out += " notifiers=" + std::to_string(notifiers);
  out += " external=" + std::to_string(process->object_heap()->external_memory());
  out += " finalizers_to_run=" + std::to_string(process->object_heap()->has_finalizer_to_run());
  return out;
}

// The VM finalizer nodes whose object no longer has an active finalizer: a
// message decoder that failed gave the object's memory back to the message
// (remove_disposing_finalizers clears the bit), and the node, malloced by
// the failed call, only waits for the next GC to unlink and delete it
// (VmFinalizerNode::weak_processing). The retry protocol runs that GC
// before the retry, so such a node is not an effect of the failed call.
static int dead_vm_finalizer_nodes(Process* process) {
  int count = 0;
  for (auto node : process->object_heap()->registered_vm_finalizers_) {
    if (!node->key()->has_active_finalizer()) count++;
  }
  return count;
}

static bool is_oom(Object* result) {
  if (!Primitive::is_error(result)) return false;
  Object* value = Primitive::unmark_from_error(program, result);
  return value == program->malloc_failed() ||
         value == program->allocation_failed() ||
         value == program->cross_process_gc();
}

// ---------------------------------------------------------------------------
// The cases.

struct Case {
  const char* name;
  int module;
  int index;
  // Builds the arguments in a fresh process (and any state they need).
  std::function<std::vector<Object*>(Process*)> setup;
  // The result depends on the time or on randomness: only compared by
  // its kind.
  bool nondeterministic = false;
  // The primitive fails for want of memory when the process is over its
  // limit (task_has_messages), not when an allocation fails.
  bool over_limit = false;
};

struct Outcome {
  std::string result;
  std::string args;
  std::string state;
  int allocations;
  int live;
  int foreign;
};

static std::string kind_of(Process* process, Object* result, bool nondeterministic) {
  if (!nondeterministic) return dump_values(process, { result });
  if (is_smi(result)) return "smi";
  if (Primitive::is_error(result)) return dump_values(process, { result });
  return "tag" + std::to_string(HeapObject::cast(result)->class_tag());
}

static Object* armed_call(Process* process, const Case& c, const std::vector<Object*>& args, int fail) {
  events = 0;
  fail_from = fail;
  live_count = 0;
  foreign_frees = 0;
  armed = true;
  Object* result = call(process, c.module, c.index, args);
  armed = false;
  return result;
}

static int failures = 0;
static int dead_nodes_seen = 0;  // Failed calls that left a node for the GC.

static void mismatch(const Case& c, int k, const char* what, const std::string& expected, const std::string& actual) {
  failures++;
  printf("FAIL %s, allocation %d fails: %s\n  expected: %s\n  actual:   %s\n",
         c.name, k, what, expected.c_str(), actual.c_str());
}

static void run(const Case& c) {
  // The reference: no failure.
  Outcome reference;
  {
    Process* process = new_process();
    std::vector<Object*> args = c.setup(process);
    Object* result = armed_call(process, c, args, -1);
    reference.result = kind_of(process, result, c.nondeterministic);
    reference.args = c.nondeterministic ? "" : dump_values(process, args);
    reference.state = process_state(process);
    if (is_oom(result)) mismatch(c, -1, "the call without failures failed for want of memory", "", reference.result);
    reference.allocations = events;
    reference.live = live_count;
    reference.foreign = foreign_frees;
    delete_process(process);
  }
  int checked = 0;
  int points = c.over_limit ? 1 : reference.allocations;
  for (int k = 0; k < points; k++) {
    Process* process = new_process();
    std::vector<Object*> args = c.setup(process);
    std::string args_before = dump_values(process, args);
    std::string state_before = process_state(process);
    int dead_before = dead_vm_finalizer_nodes(process);
    Object* result;
    if (c.over_limit) {
      // The process is over its memory limit (no allocation fails).
      ObjectHeap* heap = process->object_heap();
      word limit = heap->limit_;
      word max = heap->max_heap_size_;
      heap->max_heap_size_ = 1;
      heap->limit_ = 0;
      result = armed_call(process, c, args, -1);
      heap->limit_ = limit;
      heap->max_heap_size_ = max;
    } else {
      result = armed_call(process, c, args, k);
    }
    if (is_oom(result)) {
      checked++;
      std::string args_after = dump_values(process, args);
      std::string state_after = process_state(process);
      if (args_after != args_before) mismatch(c, k, "the failed call changed its arguments", args_before, args_after);
      if (state_after != state_before) mismatch(c, k, "the failed call changed the process", state_before, state_after);
      int dead = dead_vm_finalizer_nodes(process) - dead_before;
      if (live_count != dead || foreign_frees != 0) {
        mismatch(c, k, "the failed call kept or freed malloced memory",
                 std::to_string(dead) + " kept (finalizer nodes the GC unlinks), 0 freed",
                 std::to_string(live_count) + " kept, " + std::to_string(foreign_frees) + " freed");
      }
      if (dead > 0) dead_nodes_seen++;
      // The retry, with allocation working again.
      Object* retry = armed_call(process, c, args, -1);
      std::string retry_result = kind_of(process, retry, c.nondeterministic);
      if (retry_result != reference.result) mismatch(c, k, "the retry's result", reference.result, retry_result);
      if (!c.nondeterministic) {
        std::string retry_args = dump_values(process, args);
        if (retry_args != reference.args) mismatch(c, k, "the arguments after the retry", reference.args, retry_args);
      }
      std::string retry_state = process_state(process);
      if (retry_state != reference.state) mismatch(c, k, "the process after the retry", reference.state, retry_state);
      if (live_count != reference.live || foreign_frees != reference.foreign) {
        mismatch(c, k, "malloc balance of the retry",
                 std::to_string(reference.live) + " kept, " + std::to_string(reference.foreign) + " freed",
                 std::to_string(live_count) + " kept, " + std::to_string(foreign_frees) + " freed");
      }
    }
    delete_process(process);
  }
  printf("%-40s %2d allocations, %2d out-of-memory failures checked\n", c.name, reference.allocations, checked);
}

// The tags of src/messaging.cc, for a hand-made message.
static const uint8 TAG_POSITIVE_SMI = 1;
static const uint8 TAG_ARRAY = 6;
static const uint8 TAG_BYTE_ARRAY = 12;

// An encoded message: [5, an out-of-line byte array of 300 bytes, [0, 0]].
static uint8* message() {
  uint8* buffer = unvoid_cast<uint8*>(__real_malloc(64));
  word i = 0;
  buffer[i++] = TAG_ARRAY;
  buffer[i++] = 3;
  buffer[i++] = TAG_POSITIVE_SMI;
  buffer[i++] = 5;
  buffer[i++] = TAG_BYTE_ARRAY;
  buffer[i++] = 300 % 128 + 128;
  buffer[i++] = 300 / 128;
  uint8* block = unvoid_cast<uint8*>(__real_malloc(300));
  memset(block, 0x55, 300);
  memcpy(&buffer[i], &block, sizeof(block));
  i += sizeof(block);
  buffer[i++] = TAG_ARRAY;
  buffer[i++] = 2;
  buffer[i++] = TAG_POSITIVE_SMI;
  buffer[i++] = 0;
  buffer[i++] = TAG_POSITIVE_SMI;
  buffer[i++] = 0;
  return buffer;
}

static std::vector<Case> cases() {
  std::vector<Case> result;
  auto add = [&](const char* name, int module, int index,
                 std::function<std::vector<Object*>(Process*)> setup, bool nondeterministic = false) {
    Case c;
    c.name = name;
    c.module = module;
    c.index = index;
    c.setup = setup;
    c.nondeterministic = nondeterministic;
    result.push_back(c);
  };
  const int core = MODULE_INDEX_core;
  const int64 BIG = 1LL << 50;
  const int64 G = 1LL << 62;

#define CORE(name) #name, core, CORE_##name
  // Allocating results.
  add(CORE(array_expand), [](Process* p) -> std::vector<Object*> {
    return { array(p, 3, smi(1)), smi(3), smi(10), smi(2) };
  });
  add(CORE(array_new), [](Process* p) -> std::vector<Object*> { return { smi(5), smi(0) }; });
  add(CORE(byte_array_new), [](Process* p) -> std::vector<Object*> { return { smi(10), smi(7) }; });
  add("byte_array_new (external)", core, CORE_byte_array_new,
      [](Process* p) -> std::vector<Object*> { return { smi(100000), smi(0) }; });
  add(CORE(byte_array_convert_to_string), [](Process* p) -> std::vector<Object*> {
    return { str(p, "hello"), smi(1), smi(4) };
  });
  add(CORE(concat_strings), [](Process* p) -> std::vector<Object*> {
    Array* a = array(p, 2, smi(0));
    a->at_put(0, str(p, "ab"));
    a->at_put(1, str(p, "cd"));
    return { a };
  });
  add(CORE(string_add), [](Process* p) -> std::vector<Object*> { return { str(p, "ab"), str(p, "cd") }; });
  add(CORE(string_slice), [](Process* p) -> std::vector<Object*> { return { str(p, "hello"), smi(1), smi(3) }; });
  add(CORE(string_from_rune), [](Process* p) -> std::vector<Object*> { return { smi(0x1F600) }; });
  add(CORE(string_to_utf_16), [](Process* p) -> std::vector<Object*> { return { str(p, "hello") }; });
  add(CORE(utf_16_to_string), [](Process* p) -> std::vector<Object*> { return { bytes(p, 8) }; });
  add(CORE(float_add), [](Process* p) -> std::vector<Object*> { return { dbl(p, 1.5), dbl(p, 2.25) }; });
  add(CORE(float_subtract), [](Process* p) -> std::vector<Object*> { return { dbl(p, 1.5), dbl(p, 2.25) }; });
  add(CORE(float_multiply), [](Process* p) -> std::vector<Object*> { return { dbl(p, 1.5), dbl(p, 2.25) }; });
  add(CORE(float_divide), [](Process* p) -> std::vector<Object*> { return { dbl(p, 1.5), dbl(p, 2.25) }; });
  add(CORE(float_mod), [](Process* p) -> std::vector<Object*> { return { dbl(p, 7.5), dbl(p, 2.25) }; });
  add(CORE(float_unary_minus), [](Process* p) -> std::vector<Object*> { return { dbl(p, 1.5) }; });
  add(CORE(float_sqrt), [](Process* p) -> std::vector<Object*> { return { dbl(p, 2.0) }; });
  add(CORE(float_ceil), [](Process* p) -> std::vector<Object*> { return { dbl(p, 2.5) }; });
  add(CORE(float_floor), [](Process* p) -> std::vector<Object*> { return { dbl(p, 2.5) }; });
  add(CORE(float_trunc), [](Process* p) -> std::vector<Object*> { return { dbl(p, 2.5) }; });
  add(CORE(float_round), [](Process* p) -> std::vector<Object*> { return { dbl(p, 2.34567), smi(2) }; });
  add(CORE(float_to_raw), [](Process* p) -> std::vector<Object*> { return { dbl(p, 1e300) }; });
  add(CORE(float_to_raw32), [](Process* p) -> std::vector<Object*> { return { dbl(p, -2.5) }; });
  add(CORE(float_parse), [](Process* p) -> std::vector<Object*> {
    return { str(p, "12.5x"), smi(0), smi(4), smi(0) };
  });
  add(CORE(float_to_string), [](Process* p) -> std::vector<Object*> { return { dbl(p, 2.5), p->null_object() }; });
  add("float_to_string (precision)", core, CORE_float_to_string,
      [](Process* p) -> std::vector<Object*> { return { dbl(p, 1e300), smi(64) }; });
  add(CORE(number_to_float), [](Process* p) -> std::vector<Object*> { return { smi(3) }; });
  add(CORE(number_to_integer), [](Process* p) -> std::vector<Object*> { return { dbl(p, 9e18) }; });
  add(CORE(raw_to_float), [](Process* p) -> std::vector<Object*> { return { big(p, BIG) }; });
  add(CORE(raw32_to_float), [](Process* p) -> std::vector<Object*> { return { smi(0x3f800000) }; });
  add(CORE(int64_to_string), [](Process* p) -> std::vector<Object*> { return { big(p, -BIG), smi(7) }; });
  add(CORE(uint64_to_string), [](Process* p) -> std::vector<Object*> { return { big(p, -BIG) }; });
  add(CORE(printf_style_int64_to_string), [](Process* p) -> std::vector<Object*> { return { big(p, BIG), smi(16) }; });
  add(CORE(smi_to_string_base_10), [](Process* p) -> std::vector<Object*> { return { smi(-12345) }; });
  add(CORE(int_parse), [](Process* p) -> std::vector<Object*> {
    return { str(p, "123456789012345"), smi(0), smi(15), smi(0) };
  });
  // Large-integer results on both widths (G = 2^62 is above the 64-bit
  // smi range).
  add(CORE(large_integer_add), [](Process* p) -> std::vector<Object*> { return { big(p, G / 2), big(p, G / 2) }; });
  add(CORE(large_integer_subtract), [](Process* p) -> std::vector<Object*> { return { big(p, G / 2), big(p, -G / 2) }; });
  add(CORE(large_integer_multiply), [](Process* p) -> std::vector<Object*> { return { big(p, G / 2), smi(3) }; });
  add(CORE(large_integer_divide), [](Process* p) -> std::vector<Object*> { return { big(p, G + 6), smi(1) }; });
  add(CORE(large_integer_mod), [](Process* p) -> std::vector<Object*> { return { big(p, G + 5), big(p, G + 6) }; });
  add(CORE(large_integer_unary_minus), [](Process* p) -> std::vector<Object*> { return { big(p, -G) }; });
  add(CORE(large_integer_not), [](Process* p) -> std::vector<Object*> { return { big(p, G) }; });
  add(CORE(large_integer_and), [](Process* p) -> std::vector<Object*> { return { big(p, G + 1), big(p, G + 3) }; });
  add(CORE(large_integer_or), [](Process* p) -> std::vector<Object*> { return { big(p, G), smi(1) }; });
  add(CORE(large_integer_xor), [](Process* p) -> std::vector<Object*> { return { big(p, G), smi(1) }; });
  add(CORE(large_integer_shift_left), [](Process* p) -> std::vector<Object*> { return { big(p, G / 4), smi(2) }; });
  add(CORE(large_integer_shift_right), [](Process* p) -> std::vector<Object*> { return { big(p, G + 3), smi(0) }; });
  add(CORE(large_integer_unsigned_shift_right), [](Process* p) -> std::vector<Object*> { return { big(p, -1), smi(1) }; });
  add(CORE(smi_add), [](Process* p) -> std::vector<Object*> { return { smi(Smi::MAX_SMI_VALUE), smi(Smi::MAX_SMI_VALUE) }; });
  add(CORE(smi_subtract), [](Process* p) -> std::vector<Object*> { return { smi(Smi::MIN_SMI_VALUE), smi(Smi::MAX_SMI_VALUE) }; });
  add(CORE(smi_multiply), [](Process* p) -> std::vector<Object*> { return { smi(Smi::MAX_SMI_VALUE / 2), smi(3) }; });
  add(CORE(smi_divide), [](Process* p) -> std::vector<Object*> { return { smi(Smi::MIN_SMI_VALUE), smi(-1) }; });
  add(CORE(smi_mod), [=](Process* p) -> std::vector<Object*> { return { smi(5), big(p, G) }; });
  add(CORE(smi_unary_minus), [](Process* p) -> std::vector<Object*> { return { smi(Smi::MIN_SMI_VALUE) }; });
  add(CORE(smi_and), [=](Process* p) -> std::vector<Object*> { return { smi(-1), big(p, G + 1) }; });
  add(CORE(smi_or), [=](Process* p) -> std::vector<Object*> { return { smi(1), big(p, G) }; });
  add(CORE(smi_xor), [=](Process* p) -> std::vector<Object*> { return { smi(1), big(p, G) }; });
  add(CORE(smi_shift_left), [](Process* p) -> std::vector<Object*> { return { smi(1), smi(WORD_BIT_SIZE - 2) }; });
  add(CORE(smi_unsigned_shift_right), [](Process* p) -> std::vector<Object*> { return { smi(-1), smi(1) }; });
  add(CORE(read_int_big_endian), [](Process* p) -> std::vector<Object*> { return { p->null_object(), bytes(p, 17), smi(8), smi(9) }; });
  add(CORE(read_uint_big_endian), [](Process* p) -> std::vector<Object*> { return { p->null_object(), bytes(p, 17), smi(8), smi(9) }; });
  add(CORE(read_int_little_endian), [](Process* p) -> std::vector<Object*> { return { p->null_object(), bytes(p, 17), smi(8), smi(9) }; });
  add(CORE(read_uint_little_endian), [](Process* p) -> std::vector<Object*> { return { p->null_object(), bytes(p, 17), smi(8), smi(9) }; });
  add(CORE(crc), [=](Process* p) -> std::vector<Object*> {
    return { big(p, BIG), smi(64), bytes(p, 16), smi(0), smi(16), bytes(p, 256) };
  });
  add(CORE(time_info), [](Process* p) -> std::vector<Object*> { return { smi(1000000), p->true_object() }; });
  add(CORE(seconds_since_epoch_local), [](Process* p) -> std::vector<Object*> {
    return { smi(2020), smi(1), smi(2), smi(3), smi(4), smi(5), p->null_object() };
  });
  add(CORE(platform), [](Process* p) -> std::vector<Object*> { return {}; });
  add(CORE(architecture), [](Process* p) -> std::vector<Object*> { return {}; });
  add(CORE(time), [](Process* p) -> std::vector<Object*> { return { p->false_object() }; }, true);
  add(CORE(get_real_time_clock), [](Process* p) -> std::vector<Object*> { return {}; }, true);

  // Copy-on-write byte arrays (MutableBlob): the copy is an allocation.
  add(CORE(byte_array_replace), [](Process* p) -> std::vector<Object*> {
    return { cow(p, 8), smi(1), bytes(p, 4), smi(0), smi(4) };
  });
  add(CORE(string_write_to_byte_array), [](Process* p) -> std::vector<Object*> {
    return { str(p, "abc"), cow(p, 8), smi(0), smi(3), smi(2) };
  });
  add(CORE(put_uint_big_endian), [](Process* p) -> std::vector<Object*> {
    return { p->null_object(), cow(p, 8), smi(4), smi(2), smi(0x12345678) };
  });
  add(CORE(put_uint_little_endian), [](Process* p) -> std::vector<Object*> {
    return { p->null_object(), cow(p, 8), smi(4), smi(2), smi(0x12345678) };
  });
  add(CORE(put_float_64_little_endian), [](Process* p) -> std::vector<Object*> {
    return { p->null_object(), cow(p, 8), smi(0), dbl(p, 1.5) };
  });
  add(CORE(put_float_32_little_endian), [](Process* p) -> std::vector<Object*> {
    return { p->null_object(), cow(p, 8), smi(4), dbl(p, 1.5) };
  });
  add("bitmap.byte_zap", MODULE_INDEX_bitmap, BITMAP_byte_zap, [](Process* p) -> std::vector<Object*> {
    return { cow(p, 8), smi(3) };
  });
  add("bitmap.blit", MODULE_INDEX_bitmap, BITMAP_blit, [](Process* p) -> std::vector<Object*> {
    return { cow(p, 16), smi(1), smi(4), bytes(p, 16), smi(1), smi(4), smi(4), p->null_object(),
             smi(0), smi(0xff), smi(0) };
  });

  // Process state: finalizers, messages, arguments, timers, notifiers.
  add(CORE(add_finalizer), [](Process* p) -> std::vector<Object*> { return { list(p, 1, 2), p->null_object() }; });
  add(CORE(task_has_messages), [](Process* p) -> std::vector<Object*> {
    SystemMessage* m = _new SystemMessage(7, 0, 1, message());
    if (m == null || !p->_append_message(m)) FATAL("no message");
    return {};
  });
  result.back().over_limit = true;
  add(CORE(process_send), [](Process* p) -> std::vector<Object*> {
    Array* a = array(p, 3, smi(0));
    a->at_put(0, str(p, "hello"));
    a->at_put(1, bytes(p, 200, true));  // Transferred: neutered when the message is made.
    a->at_put(2, bytes(p, 300));        // Copied out of line.
    return { smi(1000000), smi(0), a };
  });
  add(CORE(task_receive_message), [](Process* p) -> std::vector<Object*> {
    SystemMessage* m = _new SystemMessage(7, 0, 1, message());
    if (m == null || !p->_append_message(m)) FATAL("no message");
    return {};
  });
  add(CORE(main_arguments), [](Process* p) -> std::vector<Object*> {
    p->set_main_arguments(message());
    return {};
  });
  add(CORE(spawn_arguments), [](Process* p) -> std::vector<Object*> {
    p->set_spawn_arguments(message());
    return {};
  });
  add("timer.init", MODULE_INDEX_timer, TIMER_init, [](Process* p) -> std::vector<Object*> { return {}; });
  add("timer.create", MODULE_INDEX_timer, TIMER_create, [](Process* p) -> std::vector<Object*> {
    Object* group = call(p, MODULE_INDEX_timer, TIMER_init, {});
    return { check(Primitive::is_error(group) ? null : group) };
  });
  add("events.register_monitor_notifier", MODULE_INDEX_events, EVENTS_register_monitor_notifier,
      [](Process* p) -> std::vector<Object*> {
    Object* group = call(p, MODULE_INDEX_timer, TIMER_init, {});
    if (Primitive::is_error(group)) FATAL("timer.init");
    Object* timer = call(p, MODULE_INDEX_timer, TIMER_create, { group });
    if (Primitive::is_error(timer)) FATAL("timer.create");
    return { list(p, 0, 1), group, timer };
  });
#undef CORE
  return result;
}

}  // namespace toit

int main(int argc, char** argv) {
  using namespace toit;
  if (argc != 2) FATAL("expected fixture source");
  FlashRegistry::set_up();
  OS::set_up();
  ObjectMemory::set_up();
  auto bundle = SnapshotBundle::invalid();
  {
    compiler::Compiler compiler;
    bundle = compiler.compile(argv[1], null, null, {
      .dep_file = null,
      .dep_format = compiler::Compiler::DepFormat::none,
      .project_root = null,
      .force = false,
      .werror = true,
    });
  }
  if (!bundle.is_valid()) FATAL("fixture compilation failed");
  {
    // The test's own containers use the throwing new (the compiler
    // disallows it again when it is done); the VM uses _new.
    AllowThrowingNew allow_throwing_new;
    VM vm;
    vm.event_manager()->add_event_source(_new TimerEventSource());
    auto image = bundle.snapshot().read_image(null);
    program = image.program();
    group = ProcessGroup::create(1, program);
    for (auto& c : cases()) run(c);
    delete group;
    image.release();
  }
  free(bundle.buffer());
  ObjectMemory::tear_down();
  OS::tear_down();
  FlashRegistry::tear_down();
  if (failures != 0) {
    printf("%d failures\n", failures);
    return 1;
  }
  printf("All out-of-memory failures left no visible effect (%d left finalizer nodes for the GC).\n", dead_nodes_seen);
  return 0;
}

#else  // !defined(__linux__)

// The allocation failures need the GNU linker's --wrap (CMakeLists.txt).
int main(int argc, char** argv) {
  return 0;
}

#endif  // defined(__linux__)
