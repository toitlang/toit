// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

// libFuzzer harness for the message decoders (src/messaging.cc).
//
// The input is decoded as TISON (the format that untrusted code can feed to
// the decoder directly through 'tison_decode'). If decoding succeeds, the
// value is sent through the inter-process path exactly like process_send
// and the receiving side do it: MessageEncoder (size pass, then encoding),
// take_buffer, MessageDecoder on the receiving process,
// register_external_allocations, and freeing the buffer. Both values are
// then TISON-encoded again and must produce identical bytes.
//
// Raw bytes are not fed to the IPC decoder directly: IPC buffers carry raw
// pointers (external strings and byte arrays) by design and are only ever
// produced by the VM's own encoder.

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "../../src/top.h"
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
#include "../../src/snapshot_bundle.h"
#include "../../src/vm.h"

extern unsigned char toit_run_snapshot[];
extern unsigned int toit_run_snapshot_len;

namespace toit {

static VM* vm = null;
static Program* program = null;
static ProcessGroup* group = null;
static Process* process = null;
static int uses = 0;

// Each process heap only grows (there is no GC in the harness), so the
// process is replaced regularly.
static const int USES_PER_PROCESS = 32;

static void new_process() {
  if (process != null) {
    group->remove(process);
    delete process;
  }
  InitialMemoryManager manager;
  if (!manager.allocate()) abort();
  manager.global_variables = program->global_variables.copy();
  process = _new Process(program, group, null, &manager);
  uses = 0;
}

static uint8* tison_encode(Object* object, word* length_return) {
  TisonEncoder size_encoder(process);
  if (!size_encoder.encode(object)) return null;
  word size = size_encoder.size();
  uint8* buffer = unvoid_cast<uint8*>(malloc(size));
  TisonEncoder encoder(process, buffer, size_encoder.payload_size());
  if (!encoder.encode(object)) {
    // The size pass succeeded, so this must succeed too.
    abort();
  }
  *length_return = size;
  return buffer;
}

static void fuzz(const uint8* data, size_t size) {
  if (process == null || ++uses > USES_PER_PROCESS) new_process();

  TisonDecoder decoder(process, data, static_cast<word>(size));
  Object* decoded = decoder.decode();
  if (!decoder.success()) return;

  word original_length = 0;
  uint8* original = tison_encode(decoded, &original_length);
  if (original == null) return;  // For example nested too deeply for the encoder.

  // Send the value through the IPC encoder and decoder.
  word buffer_size;
  { MessageEncoder size_encoder(process, null);
    if (!size_encoder.encode(decoded)) abort();
    buffer_size = size_encoder.size();
  }
  uint8* buffer = unvoid_cast<uint8*>(malloc(buffer_size));
  MessageEncoder encoder(process, buffer);
  if (!encoder.encode(decoded)) abort();
  uint8* message = encoder.take_buffer();

  MessageDecoder receiver(process, message);
  Object* received = receiver.decode();
  if (!receiver.success()) {
    // The decoder must accept everything the encoder produces (unless
    // the process heap is full).
    if (!receiver.allocation_failed()) abort();
    receiver.remove_disposing_finalizers();
    MessageDecoder::deallocate(message);
    free(original);
    return;
  }
  receiver.register_external_allocations();
  free(message);  // Keeps the externals, which are now owned by the heap.

  word copy_length = 0;
  uint8* copy = tison_encode(received, &copy_length);
  if (copy == null) abort();
  if (copy_length != original_length || memcmp(copy, original, copy_length) != 0) abort();
  free(copy);
  free(original);
}

}  // namespace toit

extern "C" int LLVMFuzzerInitialize(int* argc, char*** argv) {
  using namespace toit;
  FlashRegistry::set_up();
  OS::set_up();
  ObjectMemory::set_up();
  vm = _new VM();
  SnapshotBundle bundle(toit_run_snapshot, toit_run_snapshot_len);
  if (!bundle.is_valid()) abort();
  ProgramImage image = bundle.snapshot().read_image(null);
  if (!image.is_valid()) abort();
  program = image.program();
  group = ProcessGroup::create(1, program);
  return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  toit::fuzz(data, size);
  return 0;
}
