// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The C++ string_at primitive on strings whose bytes are not valid UTF-8
// (verified/cxx/annotated/README.md, "Findings", wave 10).
//
// Nothing validates the bytes of a string: not the string literals of a
// program image (the verifier checks only the objects' extents), and not a
// concatenation of string slices whose boundaries a program's own library
// chose (string_add and concat_strings copy what byte_content decodes; the
// SDK's StringSlice_ checks its boundaries, a program's own copy need not).
// Until wave 10, string_at read as many continuation bytes as a lead byte
// announced (up to 7 for 0xff) without looking at the string's length: for
// a lead byte near the end it read the terminator and then the bytes after
// the string (the next heap object, or past the malloced block of an
// external string; AddressSanitizer reports it), returned some of their
// bits in the result, and shifted by a negative count for 0xff. The Rust
// port of string_at declines such strings and leaves them to the C++.
// Now a lead byte of 0xf8 or above, or one whose sequence runs past the
// end, gives null, like a continuation byte.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <vector>

#include "../../src/top.h"

#include "../../src/compiler/compiler.h"
#include "../../src/event_sources/timer.h"
#include "../../src/flags.h"
#include "../../src/flash_registry.h"
#include "../../src/heap.h"
#include "../../src/objects_inline.h"
#include "../../src/os.h"
#include "../../src/primitive.h"
#include "../../src/process.h"
#include "../../src/process_group.h"
#include "../../src/scheduler.h"
#include "../../src/snapshot.h"
#include "../../src/vm.h"

namespace toit {

#define MODULE_INDEX(name, entry) MODULE_INDEX_##name,
enum { MODULES(MODULE_INDEX) };
#undef MODULE_INDEX

#define CORE_INDEX(name, arity) CORE_##name,
enum { MODULE_CORE(CORE_INDEX) };
#undef CORE_INDEX

typedef Object* (*PrimitiveFunction)(Process* process, Object** args);

static Program* program = null;
static int failures = 0;

static void expect(bool condition, const char* what, int line) {
  if (condition) return;
  printf("FAIL (line %d): %s\n", line, what);
  failures++;
}
#define EXPECT(condition) expect(condition, #condition, __LINE__)

static Object* call(Process* process, int index, const std::vector<Object*>& args) {
  const PrimitiveEntry* entry = Primitive::at(MODULE_INDEX_core, index);
  if (entry == null || entry->function == null) FATAL("no primitive %d", index);
  Object* slots[8];
  word n = args.size();
  for (word i = 0; i < n; i++) slots[n - 1 - i] = args[i];
  return reinterpret_cast<PrimitiveFunction>(entry->function)(process, &slots[n - 1]);
}

static String* make_string(Process* process, const uint8* bytes, word length) {
  String* result = process->allocate_string(length);
  if (result == null) FATAL("allocation failed %zd", static_cast<size_t>(length));
  String::MutableBytes content(result);
  memcpy(content.address(), bytes, length);
  return result;
}

static Object* string_at(Process* process, Object* receiver, word index) {
  return call(process, CORE_string_at, { receiver, Smi::from(index) });
}

static bool is_smi_value(Object* result, word value) {
  return is_smi(result) && Smi::value(result) == value;
}

// Every lead byte that announces more bytes than the string has left, and
// every byte of 0xf8 and above, as the last byte of a string of `length`
// bytes (7: the content and its terminator fill the internal string's
// words exactly, so the bytes after the terminator are the next object's).
static void test_truncated(Process* process, word length) {
  std::vector<uint8> bytes(length, 'a');
  String* s = make_string(process, bytes.data(), length);
  for (int lead = 0xc0; lead <= 0xff; lead++) {
    String::MutableBytes(s).address()[length - 1] = lead;
    Object* result = string_at(process, s, length - 1);
    EXPECT(result == process->null_object());
    if (result != process->null_object()) printf("  lead 0x%x, length %zd\n", lead, static_cast<size_t>(length));
  }
}

static void test_valid(Process* process) {
  // "a€" and "€a": the characters still decode.
  const uint8 euro_a[] = { 0xe2, 0x82, 0xac, 'a' };
  String* s = make_string(process, euro_a, 4);
  EXPECT(is_smi_value(string_at(process, s, 0), 0x20ac));
  EXPECT(string_at(process, s, 1) == process->null_object());
  EXPECT(is_smi_value(string_at(process, s, 3), 'a'));
  // A four-byte character at the very end.
  const uint8 clef[] = { 'x', 0xf0, 0x9d, 0x84, 0x9e };
  s = make_string(process, clef, 5);
  EXPECT(is_smi_value(string_at(process, s, 1), 0x1d11e));
  // An overlong sequence decodes to its value (a debug build asserted).
  const uint8 overlong[] = { 0xc0, 0x80 };
  s = make_string(process, overlong, 2);
  EXPECT(is_smi_value(string_at(process, s, 0), 0));
}

// A string slice whose `to` cuts a character (a program's own StringSlice_
// can), concatenated: string_add copies the cut bytes into a new string.
static void test_cut_slice(Process* process) {
  const uint8 a_euro[] = { 'a', 0xe2, 0x82, 0xac };
  String* s = make_string(process, a_euro, 4);
  Instance* slice = process->object_heap()->allocate_instance(program->string_slice_class_id());
  if (slice == null) FATAL("allocation failed");
  slice->at_put(Instance::STRING_SLICE_STRING_INDEX, s);
  slice->at_put(Instance::STRING_SLICE_FROM_INDEX, Smi::from(0));
  slice->at_put(Instance::STRING_SLICE_TO_INDEX, Smi::from(2));
  // On the slice itself the sequence runs past the slice's end.
  EXPECT(string_at(process, slice, 1) == process->null_object());
  String* empty = make_string(process, null, 0);
  Object* joined = call(process, CORE_string_add, { slice, empty });
  EXPECT(is_string(joined));
  if (!is_string(joined)) return;
  EXPECT(String::cast(joined)->length() == 2);
  EXPECT(string_at(process, joined, 1) == process->null_object());
}

// An external string (malloced, length + 1 bytes for the terminator) ending
// in a lead byte: the old code read past the malloced block.
static void test_external(Process* process) {
  word length = String::max_internal_size_in_process() + 100;
  // Exactly length + 1 bytes, as Process::allocate_string mallocs them.
  uint8* memory = static_cast<uint8*>(malloc(length + 1));
  memset(memory, 'b', length);
  memory[length] = 0;
  String* s = process->object_heap()->allocate_external_string(length, memory, true);
  if (s == null) FATAL("allocation failed");
  EXPECT(!s->content_on_heap());
  for (int lead : { 0xf0, 0xff }) {
    memory[length - 1] = lead;
    EXPECT(string_at(process, s, length - 1) == process->null_object());
  }
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
    AllowThrowingNew allow_throwing_new;
    VM vm;
    vm.event_manager()->add_event_source(_new TimerEventSource());
    auto image = bundle.snapshot().read_image(null);
    program = image.program();
    ProcessGroup* group = ProcessGroup::create(1, program);
    InitialMemoryManager manager;
    if (!manager.allocate()) FATAL("no memory");
    manager.global_variables = program->global_variables.copy();
    Process* process = _new Process(program, group, null, &manager);
    test_valid(process);
    for (word length = 1; length <= 9; length++) test_truncated(process, length);
    test_cut_slice(process);
    test_external(process);
    group->begin_process_teardown(process);
    delete process;
    group->finish_process_teardown();
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
  printf("string_at reads only inside the string.\n");
  return 0;
}
