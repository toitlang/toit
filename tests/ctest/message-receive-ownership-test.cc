// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The ownership of a message's out-of-line blocks (malloced copies and
// transferred byte arrays) when the receiver decodes it: the decoded
// external strings and byte arrays take them (their VM finalizer frees
// them), and on a failure the receiver gives them back to the message
// (MessageDecoder::remove_disposing_finalizers clears the finalizer bits),
// which frees them when it is deleted (MessageDecoder::deallocate).
//
// Two bugs, found by the VeriFast proof of the receive path
// (verified/cxx/annotated/decoder):
//
// 1. A double free. The objects given back keep their VM finalizer node
//    (only the bit is cleared; the node is removed at the next GC), and
//    when the heap died before that GC, VmFinalizerNode::heap_dying freed
//    their memory without looking at the bit: a second free of every block
//    the message then frees itself. A decode that fails twice (an
//    allocation failure, the retry after the GC fails too: the primitive
//    throws) followed by the end of the process is enough; a sandboxed
//    receiver controls both (its heap limit, its exit).
// 2. A leak. A malformed message (one the decoder rejects) was delivered
//    as decoded: the receiver freed the buffer but not the out-of-line
//    blocks after the error. Now it is dropped and freed in full.
//
// The test drives the main_arguments primitive (the same code as
// spawn_arguments and task_receive_message) on hand-made messages and
// deletes the process as the scheduler does when it terminates. Without
// fix 1 the deletion aborts (glibc detects the double free); without fix 2
// the blocks after the error stay allocated (mallinfo2, glibc only).

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
#include "../../src/messaging.h"
#include "../../src/objects_inline.h"
#include "../../src/os.h"
#include "../../src/primitive.h"
#include "../../src/process.h"
#include "../../src/process_group.h"
#include "../../src/scheduler.h"
#include "../../src/snapshot.h"
#include "../../src/vm.h"

namespace toit {

// The tags of src/messaging.cc.
static const uint8 TAG_POSITIVE_SMI = 1;
static const uint8 TAG_ARRAY = 6;
static const uint8 TAG_BYTE_ARRAY = 12;

// A large block is mapped by malloc, so mallinfo2 sees it come and go (a
// leak). A small one, freed twice, is caught by glibc's tcache check (a
// double free); its size is used by nothing else.
static const word LARGE = 1 << 20;
static const word SMALL = 232;

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

static uint8* new_block(word size) {
  uint8* block = unvoid_cast<uint8*>(malloc(size));
  if (block == null) FATAL("malloc failed");
  memset(block, 0x55, size);
  return block;
}

static size_t mapped_bytes() {
#ifdef __GLIBC__
  return mallinfo2().hblkhd;
#else
  return 0;
#endif
}

typedef Object* (*PrimitiveFunction)(Process* process, Object** args);

#define CORE_INDEX(name, arity) CORE_##name,
enum { MODULE_CORE(CORE_INDEX) };
#undef CORE_INDEX

static PrimitiveFunction main_arguments_primitive() {
  const PrimitiveEntry* entry = Primitive::at(0, CORE_main_arguments);
  if (entry == null) FATAL("no main_arguments primitive");
  return reinterpret_cast<PrimitiveFunction>(entry->function);
}

static Process* new_process(Program* program, ProcessGroup* group) {
  InitialMemoryManager manager;
  if (!manager.allocate()) FATAL("no memory");
  manager.global_variables = program->global_variables.copy();
  return _new Process(program, group, null, &manager);
}

static void delete_process(ProcessGroup* group, Process* process) {
  // As the scheduler does when a process terminates: no GC before.
  group->begin_process_teardown(process);
  delete process;
  group->finish_process_teardown();
}

// [external byte array of a SMALL block, `count` arrays of `length` zeros,
// external byte array of a LARGE block]: an array is malformed (longer
// than a process heap holds) or fails to allocate (under a heap limit).
static uint8* message(word length, word count) {
  Writer writer(64 + count * (8 + 2 * length));
  writer.byte(TAG_ARRAY);
  writer.cardinal(count + 2);
  writer.external_byte_array(new_block(SMALL), SMALL);
  for (word i = 0; i < count; i++) writer.zeros(length);
  writer.external_byte_array(new_block(LARGE), LARGE);
  return writer.buffer();
}

static Object* main_arguments(Process* process) {
  Object* args[1] = { null };
  return main_arguments_primitive()(process, &args[0]);
}

// A message that decodes: the byte arrays own the blocks, and the dying
// heap frees them.
static void decoded(Program* program, ProcessGroup* group) {
  size_t before = mapped_bytes();
  Process* process = new_process(program, group);
  process->set_main_arguments(message(2, 1));
  Object* result = main_arguments(process);
  if (Primitive::is_error(result) || !is_array(result)) FATAL("the message did not decode");
  Array* array = Array::cast(result);
  if (array->length() != 3 || !is_byte_array(array->at(0)) || !is_byte_array(array->at(2))) FATAL("wrong content");
  ByteArray::Bytes bytes(ByteArray::cast(array->at(2)));
  if (bytes.length() != LARGE || bytes.address()[LARGE - 1] != 0x55) FATAL("wrong byte array");
  delete_process(group, process);
  if (mapped_bytes() > before) FATAL("decoded: %zu bytes leaked", mapped_bytes() - before);
}

// Bug 1: an allocation failure (the first byte array took its block and
// gave it back), then the process dies before a GC.
static void allocation_failure_then_exit(Program* program, ProcessGroup* group) {
  size_t before = mapped_bytes();
  Process* process = new_process(program, group);
  // A few pages: the outer array and the first byte array fit, the long
  // arrays after them do not.
  process->set_max_heap_size(4 * TOIT_PAGE_SIZE);
  process->set_main_arguments(message(Array::max_length_in_process(), 16));
  Object* result = main_arguments(process);
  if (!Primitive::is_error(result)) FATAL("the decoding did not fail");
  if (process->main_arguments() == null) FATAL("the message was dropped");
  // The retry after the GC, as the interpreter does it, fails again.
  result = main_arguments(process);
  if (!Primitive::is_error(result)) FATAL("the decoding did not fail");
  // The message owns both blocks again; it frees them, once.
  delete_process(group, process);
  if (mapped_bytes() > before) FATAL("allocation failure: %zu bytes leaked", mapped_bytes() - before);
}

// Bug 2: a malformed message: dropped, and all of it freed.
static void malformed(Program* program, ProcessGroup* group) {
  size_t before = mapped_bytes();
  Process* process = new_process(program, group);
  process->set_main_arguments(message(Array::max_length_in_process() + 1, 1));
  Object* result = main_arguments(process);
  bool delivered = !Primitive::is_error(result);
  bool kept = process->main_arguments() != null;
  delete_process(group, process);
  if (mapped_bytes() > before) FATAL("malformed: %zu bytes leaked", mapped_bytes() - before);
  if (delivered) FATAL("a malformed message was delivered");
  if (kept) FATAL("the malformed message was kept");
}

static void run(Program* program) {
#ifdef __GLIBC__
  // A fixed threshold: the blocks are always mapped.
  mallopt(M_MMAP_THRESHOLD, 128 * 1024);
#endif
  ProcessGroup* group = ProcessGroup::create(1, program);
  decoded(program, group);
  allocation_failure_then_exit(program, group);
  malformed(program, group);
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
