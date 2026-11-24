// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The C++ integer readers and writers of byte arrays (src/primitive_core.cc:
// read_int_*, read_uint_*, put_uint_*), called directly with the widths a
// program can pass, including INT32_MIN (verified/cxx/annotated/README.md,
// "Findings", wave 9).
//
// Until wave 9, read_int_big_endian, read_int_little_endian and
// put_uint_little_endian computed `width - 1` in int before checking the
// width: undefined behavior for INT32_MIN on 64-bit targets, reachable by
// untrusted programs (the Rust ports decode the byte array first and leave
// a copy-on-write or opaque byte array to these primitives with the width
// unchecked). The undefined subtraction is caught by the VeriFast proofs
// (prims/read_bytes.render, prims/put_bytes.render; mutants
// read-int-width-overflow and put-uint-width-overflow); this test pins what
// the rewritten checks do for every width: widths outside 1..8 (0..9 for
// put_uint_big_endian, 0..8 for read_uint_*) are OUT_OF_BOUNDS, the others
// read or write exactly the bytes they name.

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

// Calls core primitive `index` with its arguments in order (ARGS reads
// __args[0], __args[-1], ...: the first argument at the highest address).
static Object* call(Process* process, int index, const std::vector<Object*>& args) {
  const PrimitiveEntry* entry = Primitive::at(MODULE_INDEX_core, index);
  if (entry == null || entry->function == null) FATAL("no primitive %d", index);
  Object* slots[8];
  word n = args.size();
  for (word i = 0; i < n; i++) slots[n - 1 - i] = args[i];
  return reinterpret_cast<PrimitiveFunction>(entry->function)(process, &slots[n - 1]);
}

static bool is_out_of_bounds(Object* result) {
  return Primitive::is_error(result) &&
      Primitive::unmark_from_error(program, result) == program->out_of_bounds();
}

static Object* integer(Process* process, int64 value) {
  if (Smi::is_valid(value)) return Smi::from(static_cast<word>(value));
  Object* result = process->object_heap()->allocate_large_integer(value);
  if (result == null) FATAL("allocation failed");
  return result;
}

static bool is_integer(Object* result, int64 value) {
  if (is_smi(result)) return Smi::value(result) == value;
  return is_large_integer(result) && LargeInteger::cast(result)->value() == value;
}

static const uint8 PATTERN[10] = { 0x81, 0x02, 0x83, 0x04, 0x85, 0x06, 0x87, 0x08, 0x89, 0x0a };

static ByteArray* pattern(Process* process) {
  ByteArray* result = process->allocate_byte_array(10);
  if (result == null) FATAL("allocation failed");
  memcpy(ByteArray::Bytes(result).address(), PATTERN, 10);
  return result;
}

// The value of `width` bytes at `offset` of PATTERN.
static int64 expected_read(bool is_signed, bool big, int width, int offset) {
  uint64 value = 0;
  for (int k = 0; k < width; k++) {
    int i = big ? offset + k : offset + width - 1 - k;
    value = (value << 8) | PATTERN[i];
  }
  if (is_signed && width < 8 && (value >> (8 * width - 1)) != 0) {
    value |= ~static_cast<uint64>(0) << (8 * width);
  }
  return static_cast<int64>(value);
}

static const int64 WIDTHS[] = { INT32_MIN, INT32_MIN + 1, -2, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, INT32_MAX };

static void test_reads(Process* process) {
  struct Reader { int index; bool is_signed; bool big; };
  const Reader readers[] = {
    { CORE_read_int_big_endian, true, true },
    { CORE_read_int_little_endian, true, false },
    { CORE_read_uint_big_endian, false, true },
    { CORE_read_uint_little_endian, false, false },
  };
  ByteArray* bytes = pattern(process);
  for (const Reader& r : readers) {
    for (int64 width : WIDTHS) {
      for (int offset = -1; offset <= 11; offset++) {
        // A smi argument: INT32_MIN only where it is one (64-bit).
        if (!Smi::is_valid(width)) continue;
        Object* result = call(process, r.index, { process->null_object(), bytes, Smi::from(width), Smi::from(offset) });
        bool valid_width = r.is_signed ? (1 <= width && width <= 8) : (0 <= width && width <= 8);
        bool valid = valid_width && 0 <= offset && offset + width <= 10;
        if (!valid) {
          EXPECT(is_out_of_bounds(result));
        } else {
          EXPECT(is_integer(result, expected_read(r.is_signed, r.big, static_cast<int>(width), offset)));
        }
      }
    }
  }
}

static void test_writes(Process* process) {
  struct Writer { int index; bool big; int max_width; };
  const Writer writers[] = {
    { CORE_put_uint_big_endian, true, 9 },
    { CORE_put_uint_little_endian, false, 8 },
  };
  const int64 value = static_cast<int64>(0xf1e2d3c4b5a69788ULL);  // Negative.
  for (const Writer& w : writers) {
    for (int64 width : WIDTHS) {
      for (int offset = -1; offset <= 11; offset++) {
        if (!Smi::is_valid(width)) continue;
        ByteArray* bytes = pattern(process);
        Object* result = call(process, w.index, { process->null_object(), bytes, Smi::from(width), Smi::from(offset), integer(process, value) });
        int min_width = w.big ? 0 : 1;
        bool valid = min_width <= width && width <= w.max_width && 0 <= offset && offset + width <= 10;
        uint8* content = ByteArray::Bytes(bytes).address();
        if (!valid) {
          EXPECT(is_out_of_bounds(result));
          EXPECT(memcmp(content, PATTERN, 10) == 0);
          continue;
        }
        EXPECT(result == process->null_object());
        // Byte k of the value (k = 0 the least significant), the arithmetic
        // shift's sign bytes beyond the eighth.
        for (int i = 0; i < 10; i++) {
          int k = w.big ? offset + static_cast<int>(width) - 1 - i : i - offset;
          bool written = offset <= i && i < offset + width;
          uint8 expected = !written ? PATTERN[i] : (k < 8 ? static_cast<uint8>(value >> (8 * k)) : 0xff);
          EXPECT(content[i] == expected);
        }
      }
    }
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
    test_reads(process);
    test_writes(process);
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
  printf("All widths and offsets behave as specified.\n");
  return 0;
}
