// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// A malformed message (one that the decoder rejects) must not be delivered,
// and all of its out-of-line data must be freed. The receiver used to
// deliver the result of the failed decoding (a null pointer, seen as 0 by
// Toit code) and to free only the message buffer, which leaked the
// out-of-line blocks after the error.
//
// The MessageEncoder doesn't produce malformed messages, so the test uses
// hand-crafted bytes. It drives the main_arguments and spawn_arguments
// primitives, which handle a received message like task_receive_message.

#include <stdlib.h>
#include <string.h>
#ifdef __GLIBC__
#include <malloc.h>
#endif

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

// The tags of src/messaging.cc.
static const uint8 TAG_POSITIVE_SMI = 1;
static const uint8 TAG_ARRAY = 6;
static const uint8 TAG_BYTE_ARRAY = 12;

// Blocks this large are mapped by malloc, so mallinfo2 sees them come and go.
static const word BLOCK_SIZE = 1 << 20;

class Writer {
 public:
  explicit Writer(word capacity)
      : buffer_(unvoid_cast<uint8*>(malloc(capacity))), capacity_(capacity) {
    if (buffer_ == null) FATAL("malloc failed");
  }

  void byte(uint8 value) {
    if (cursor_ >= capacity_) FATAL("message too long");
    buffer_[cursor_++] = value;
  }

  void cardinal(uword value) {
    while (value >= 128) {
      byte(static_cast<uint8>(value % 128 + 128));
      value >>= 7;
    }
    byte(static_cast<uint8>(value));
  }

  void pointer(void* value) {
    for (unsigned i = 0; i < sizeof(value); i++) byte(0);
    memcpy(&buffer_[cursor_ - sizeof(value)], &value, sizeof(value));
  }

  // An out-of-line byte array, as the encoder writes a transferred one.
  void external_byte_array(uint8* block, word length) {
    byte(TAG_BYTE_ARRAY);
    cardinal(length);
    pointer(block);
  }

  // An array of `length` zeros.
  void zeros(word length) {
    byte(TAG_ARRAY);
    cardinal(length);
    for (word i = 0; i < length; i++) {
      byte(TAG_POSITIVE_SMI);
      cardinal(0);
    }
  }

  uint8* buffer() const { return buffer_; }

 private:
  uint8* buffer_;
  word capacity_;
  word cursor_ = 0;
};

static uint8* new_block() {
  uint8* block = unvoid_cast<uint8*>(malloc(BLOCK_SIZE));
  if (block == null) FATAL("malloc failed");
  memset(block, 0x55, BLOCK_SIZE);
  return block;
}

static size_t mapped_bytes() {
#ifdef __GLIBC__
  return mallinfo2().hblkhd;
#else
  return 0;
#endif
}

// [byte array, array of `length` zeros, byte array]. The byte arrays are
// out of line. The middle array is malformed if it is longer than an array
// in a process can be.
static uint8* message(word length) {
  Writer writer(64 + 2 * length);
  writer.byte(TAG_ARRAY);
  writer.cardinal(3);
  writer.external_byte_array(new_block(), BLOCK_SIZE);
  writer.zeros(length);
  writer.external_byte_array(new_block(), BLOCK_SIZE);
  return writer.buffer();
}

typedef Object* (*PrimitiveFunction)(Process* process, Object** args);

#define CORE_INDEX(name, arity) CORE_##name,
enum { MODULE_CORE(CORE_INDEX) };
#undef CORE_INDEX

static Object* call_primitive(int index, Process* process) {
  const PrimitiveEntry* entry = Primitive::at(0, index);
  if (entry == null) FATAL("primitive not found");
  Object* args[1] = { null };
  return reinterpret_cast<PrimitiveFunction>(entry->function)(process, &args[0]);
}

static Process* new_process(Program* program, ProcessGroup* group) {
  InitialMemoryManager manager;
  if (!manager.allocate()) FATAL("no memory");
  manager.global_variables = program->global_variables.copy();
  return _new Process(program, group, null, &manager);
}

static void delete_process(ProcessGroup* group, Process* process) {
  group->remove(process);
  delete process;
}

static void test(Program* program, ProcessGroup* group, bool spawn, word length, bool malformed) {
  const char* name = spawn ? "spawn_arguments" : "main_arguments";
  size_t before = mapped_bytes();
  Process* process = new_process(program, group);
  if (spawn) {
    process->set_spawn_arguments(message(length));
  } else {
    process->set_main_arguments(message(length));
  }
  Object* result = call_primitive(spawn ? CORE_spawn_arguments : CORE_main_arguments, process);
  bool delivered = !Primitive::is_error(result);
  if (!malformed) {
    if (!delivered || !is_array(result)) FATAL("%s: the message did not decode", name);
    Array* array = Array::cast(result);
    if (array->length() != 3 || !is_byte_array(array->at(2))) FATAL("%s: wrong content", name);
    ByteArray::Bytes bytes(ByteArray::cast(array->at(2)));
    if (bytes.length() != BLOCK_SIZE || bytes.address()[BLOCK_SIZE - 1] != 0x55) {
      FATAL("%s: wrong byte array", name);
    }
  }
  bool kept = (spawn ? process->spawn_arguments() : process->main_arguments()) != null;
  delete_process(group, process);
  if (mapped_bytes() > before) {
    FATAL("%s: %lld bytes leaked", name, static_cast<long long>(mapped_bytes() - before));
  }
  if (malformed && delivered) FATAL("%s: a malformed message was delivered", name);
  if (kept) FATAL("%s: the message was kept", name);
}

static void run(Program* program) {
#ifdef __GLIBC__
  // A fixed threshold: the blocks are always mapped.
  mallopt(M_MMAP_THRESHOLD, 128 * 1024);
#endif
  ProcessGroup* group = ProcessGroup::create(1, program);
  for (int spawn = 0; spawn < 2; spawn++) {
    test(program, group, spawn != 0, 2, false);
    test(program, group, spawn != 0, Array::max_length_in_process() + 1, true);
  }
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
  return 0;
}
