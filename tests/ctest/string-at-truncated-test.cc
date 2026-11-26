// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The string_at primitive on strings whose bytes are not valid UTF-8.
//
// The string library only builds strings of valid UTF-8, but other strings
// exist: the string literals of a snapshot aren't validated, and native
// code can make strings. For a lead byte, string_at read as many
// continuation bytes as the lead byte announced, without looking at the
// length of the string. For a lead byte near the end of the string it read
// the terminator and the bytes after the string (the next object on the
// heap, or past the malloced block of an external string, which
// AddressSanitizer reports), and returned some of their bits. Now a
// sequence that runs past the end of the string, and a lead byte of 0xf8 or
// above, gives null, like a continuation byte.

#include <string.h>

#include "../../src/top.h"
#include "../../src/compiler/compiler.h"
#include "../../src/flags.h"
#include "../../src/flash_registry.h"
#include "../../src/heap.h"
#include "../../src/objects_inline.h"
#include "../../src/os.h"
#include "../../src/primitive.h"
#include "../../src/process.h"
#include "../../src/process_group.h"
#include "../../src/snapshot.h"
#include "../../src/vm.h"

namespace toit {

typedef Object* (*PrimitiveFunction)(Process* process, Object** args);

#define CORE_INDEX(name, arity) CORE_##name,
enum { MODULE_CORE(CORE_INDEX) };
#undef CORE_INDEX

static int failures = 0;

static void expect(bool condition, const char* what, int line) {
  if (condition) return;
  printf("FAIL (line %d): %s\n", line, what);
  failures++;
}
#define EXPECT(condition) expect(condition, #condition, __LINE__)

static Object* string_at(Process* process, Object* receiver, word index) {
  const PrimitiveEntry* entry = Primitive::at(0, CORE_string_at);
  if (entry == null) FATAL("primitive not found");
  // The arguments are passed in reverse order, with the receiver last.
  Object* args[2] = { Smi::from(index), receiver };
  return reinterpret_cast<PrimitiveFunction>(entry->function)(process, &args[1]);
}

static String* make_string(Process* process, const uint8* bytes, word length) {
  String* result = process->allocate_string(length);
  if (result == null) FATAL("allocation failed");
  String::MutableBytes content(result);
  if (length > 0) memcpy(content.address(), bytes, length);
  return result;
}

static bool is_smi_value(Object* result, word value) {
  return is_smi(result) && Smi::value(result) == value;
}

// The characters of a valid string still decode.
static void test_valid(Process* process) {
  // "€a".
  const uint8 euro_a[] = { 0xe2, 0x82, 0xac, 'a' };
  String* s = make_string(process, euro_a, 4);
  EXPECT(is_smi_value(string_at(process, s, 0), 0x20ac));
  EXPECT(string_at(process, s, 1) == process->null_object());
  EXPECT(is_smi_value(string_at(process, s, 3), 'a'));
  // A four-byte character at the very end.
  const uint8 clef[] = { 'x', 0xf0, 0x9d, 0x84, 0x9e };
  s = make_string(process, clef, 5);
  EXPECT(is_smi_value(string_at(process, s, 1), 0x1d11e));
}

// Every lead byte as the last byte of a string of the given length.
static void test_truncated(Process* process, word length) {
  uint8 bytes[16];
  memset(bytes, 'a', sizeof bytes);
  String* s = make_string(process, bytes, length);
  for (int lead = 0xc0; lead <= 0xff; lead++) {
    String::MutableBytes(s).address()[length - 1] = lead;
    Object* result = string_at(process, s, length - 1);
    EXPECT(result == process->null_object());
    if (result != process->null_object()) {
      printf("  lead byte 0x%x at the end of a string of length %d\n", lead, static_cast<int>(length));
    }
  }
}

// A three-byte sequence with only two bytes left.
static void test_truncated_inside(Process* process) {
  const uint8 bytes[] = { 'a', 'b', 0xe2, 0x82 };
  String* s = make_string(process, bytes, 4);
  EXPECT(string_at(process, s, 2) == process->null_object());
}

// An external string (malloced with length + 1 bytes for the terminator)
// that ends in a lead byte: the old code read past the malloced block.
static void test_external(Process* process) {
  word length = String::max_internal_size_in_process() + 100;
  uint8* memory = unvoid_cast<uint8*>(malloc(length + 1));
  if (memory == null) FATAL("malloc failed");
  memset(memory, 'b', length);
  memory[length] = 0;
  // Takes over the memory.
  String* s = process->object_heap()->allocate_external_string(length, memory, true);
  if (s == null) FATAL("allocation failed");
  for (int lead : { 0xf0, 0xff }) {
    memory[length - 1] = lead;
    EXPECT(string_at(process, s, length - 1) == process->null_object());
  }
}

static void run(Program* program) {
  ProcessGroup* group = ProcessGroup::create(1, program);
  InitialMemoryManager manager;
  if (!manager.allocate()) FATAL("no memory");
  manager.global_variables = program->global_variables.copy();
  Process* process = _new Process(program, group, null, &manager);
  test_valid(process);
  for (word length = 1; length <= 9; length++) test_truncated(process, length);
  test_truncated_inside(process);
  test_external(process);
  group->remove(process);
  delete process;
  delete group;
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
    VM vm;
    auto image = bundle.snapshot().read_image(null);
    run(image.program());
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
  return 0;
}
