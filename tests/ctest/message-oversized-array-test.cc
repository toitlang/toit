// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The message encoder must not produce what the decoder rejects. An array
// in a program heap can be longer than a process heap holds (format 2
// images bound an array literal only by the image, the snapshot reader by
// the program heap's larger blocks), and the inter-process decoder rejects
// such an array as malformed. task_receive_message treats a malformed
// message like a decoded one: the receiver got 0 for the message, and the
// out-of-line data after the array (up to eight external byte arrays or
// copies, transferred to the message) leaked. So a sandboxed program with
// such a literal could make the system process leak malloced memory with
// every message it sends. Now the encoder refuses such arrays and maps.
//
// The test builds the over-long array outside any heap (the encoder only
// reads it) and checks that the encoders refuse it, also as a list slice
// and as a map backing, and that an array of the longest decodable length
// still goes through both encoders and back.

#include <stdlib.h>
#include <string.h>

#include "../../src/top.h"
#include "../../src/compiler/compiler.h"
#include "../../src/flags.h"
#include "../../src/flash_registry.h"
#include "../../src/heap.h"
#include "../../src/messaging.h"
#include "../../src/objects_inline.h"
#include "../../src/os.h"
#include "../../src/process.h"
#include "../../src/process_group.h"
#include "../../src/scheduler.h"
#include "../../src/snapshot.h"
#include "../../src/vm.h"

namespace toit {

// An array of `length` smi zeros in malloced memory, with the array class's
// header: what a program heap could hold.
static Array* fake_array(Program* program, word length, uword** memory) {
  uword* words = unvoid_cast<uword*>(calloc(length + 2, WORD_SIZE));
  if (words == null) FATAL("calloc failed");
  uword header = (Smi::value(program->array_class_id()) << HeapObject::CLASS_ID_OFFSET) | ARRAY_TAG;
  words[0] = reinterpret_cast<uword>(Smi::from(header));
  words[1] = length;  // The elements are smi 0 (calloc).
  *memory = words;
  return Array::cast(HeapObject::from_address(reinterpret_cast<uword>(words)));
}

static bool ipc_size_pass(Process* process, Object* object) {
  MessageEncoder size_encoder(process, null);
  return size_encoder.encode(object);
}

static bool tison_size_pass(Process* process, Object* object) {
  TisonEncoder size_encoder(process);
  return size_encoder.encode(object);
}

static void round_trip(Process* process, Object* object, word length) {
  word size;
  { MessageEncoder size_encoder(process, null);
    if (!size_encoder.encode(object)) FATAL("the longest array was refused");
    size = size_encoder.size();
  }
  uint8* buffer = unvoid_cast<uint8*>(malloc(size));
  MessageEncoder encoder(process, buffer);
  if (!encoder.encode(object)) FATAL("the write pass failed");
  uint8* message = encoder.take_buffer();
  MessageDecoder decoder(process, message);
  Object* decoded = decoder.decode();
  // A fresh heap may not have a free page for it (the primitives retry
  // after a GC); it must not be malformed.
  if (decoder.malformed_input()) FATAL("the longest array is malformed for the decoder");
  if (decoder.success() && (!is_array(decoded) || Array::cast(decoded)->length() != length)) FATAL("wrong array");
  free(message);
}

static void run(Program* program) {
  ProcessGroup* group = ProcessGroup::create(1, program);
  InitialMemoryManager manager;
  if (!manager.allocate()) FATAL("no memory");
  manager.global_variables = program->global_variables.copy();
  Process* process = _new Process(program, group, null, &manager);

  word max = Array::max_length_in_process();
  uword* long_memory;
  Array* too_long = fake_array(program, max + 1, &long_memory);
  if (ipc_size_pass(process, too_long)) FATAL("an array longer than a process heap holds was encoded");
  if (tison_size_pass(process, too_long)) FATAL("TISON: an array longer than a process heap holds was encoded");

  // A list over it (size max + 1), and a map with it as backing.
  Instance* list = process->object_heap()->allocate_instance(program->list_class_id());
  if (list == null) FATAL("no memory");
  list->at_put(Instance::LIST_ARRAY_INDEX, too_long);
  list->at_put(Instance::LIST_SIZE_INDEX, Smi::from(max + 1));
  if (ipc_size_pass(process, list)) FATAL("a list longer than a process heap holds was encoded");
  // A map of max / 2 + 1 entries (keys and values smi 0) needs a backing
  // longer than a process heap holds.
  uword* backing_memory;
  Array* backing = fake_array(program, max + 2, &backing_memory);
  Instance* map = process->object_heap()->allocate_instance(program->map_class_id());
  if (map == null) FATAL("no memory");
  map->at_put(Instance::MAP_BACKING_INDEX, backing);
  map->at_put(Instance::MAP_SIZE_INDEX, Smi::from(max / 2 + 1));
  map->at_put(Instance::MAP_SPACES_LEFT_INDEX, Smi::from(0));
  map->at_put(Instance::MAP_INDEX_INDEX, program->null_object());
  if (ipc_size_pass(process, map)) FATAL("a map with a backing longer than a process heap holds was encoded");

  uword* ok_memory;
  Array* longest = fake_array(program, max, &ok_memory);
  round_trip(process, longest, max);

  free(long_memory);
  free(backing_memory);
  free(ok_memory);
  group->begin_process_teardown(process);
  delete process;
  group->finish_process_teardown();
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
