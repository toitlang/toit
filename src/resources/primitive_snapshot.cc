// Copyright (C) 2020 Toitware ApS.
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

#include "../top.h"

#ifndef TOIT_FREERTOS

#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../os.h"
#include "../vm.h"
#include "../process_group.h"
#include "../scheduler.h"

namespace toit {

MODULE_IMPLEMENTATION(snapshot, MODULE_SNAPSHOT)

PRIMITIVE(reader_create) {
  ARGS(Blob, bytes);

  Snapshot snapshot(bytes.address(), bytes.length());

  ProgramImage image = snapshot.read_image();
  auto relocation_bits = ImageInputStream::build_relocation_bits(image);
  ImageInputStream* input = _new ImageInputStream(image, relocation_bits);
  if (input == null) {
    image.release();
    MALLOC_FAILED;
  }
  // TODO: consider moving allocation of result to top to avoid freeing when allocation fails.
  ByteArray* result = process->object_heap()->allocate_proxy(sizeof(ImageInputStream), reinterpret_cast<uint8*>(input));
  if (result == null) {
    image.release();
    delete input;
    ALLOCATION_FAILED;
  }
  return result;
}

PRIMITIVE(reader_size_in_bytes) {
  ARGS(ByteArray, reader);
  if (ByteArray::Bytes(reader).length() != sizeof(ImageInputStream)) WRONG_TYPE;
  ImageInputStream* input = reinterpret_cast<ImageInputStream*>(ByteArray::Bytes(reader).address());
  return Smi::from(input->image().byte_size());
}

PRIMITIVE(reader_read) {
  ARGS(ByteArray, reader);
  if (ByteArray::Bytes(reader).length() != sizeof(ImageInputStream)) WRONG_TYPE;
  ImageInputStream* input = reinterpret_cast<ImageInputStream*>(ByteArray::Bytes(reader).address());
  if (input->eos()) return process->program()->null_object();
  int buffer_size_in_words = input->words_to_read();
  // Make sure we can allocate the resulting byte array before reading from ImageInputStream.
  Error* error = null;
  ByteArray* result = process->allocate_byte_array(buffer_size_in_words * WORD_SIZE, &error);
  if (result == null) return error;
  word* buffer = reinterpret_cast<word*>(ByteArray::Bytes(result).address());
  int words = input->read(buffer);
  ASSERT(buffer_size_in_words == words);
  return result;
}

PRIMITIVE(reader_close) {
  ARGS(ByteArray, reader);
  if (ByteArray::Bytes(reader).length() != sizeof(ImageInputStream)) WRONG_TYPE;
  ImageInputStream* input = reinterpret_cast<ImageInputStream*>(ByteArray::Bytes(reader).address());
  // TODO(florian): is this release correct?
  input->image().release();
  delete input;
  return process->program()->null_object();
}

PRIMITIVE(launch) {
  ARGS(Blob, bytes, int, from, int, to, bool, pass_args);

  Block* initial_block = VM::current()->heap_memory()->allocate_initial_block();
  if (!initial_block) ALLOCATION_FAILED;

  if (!(0 <= from && from <= to && to <= bytes.length())) {
    INVALID_ARGUMENT;
  }
  Snapshot snapshot(&bytes.address()[from], to - from);
  auto image = snapshot.read_image();
  int group_id = VM::current()->scheduler()->next_group_id();
  ProcessGroup* process_group = ProcessGroup::create(group_id);
  if (process_group == NULL) {
    VM::current()->heap_memory()->free_unused_block(initial_block);
    MALLOC_FAILED;
  }

  int pid = pass_args
     ? VM::current()->scheduler()->run_program(image.program(), process->args(), process_group, initial_block)
     : VM::current()->scheduler()->run_program(image.program(), {}, process_group, initial_block);
  // We don't use snapshots on devices so we assume malloc/new cannot fail.
  ASSERT(pid != Scheduler::INVALID_PROCESS_ID);
  return Smi::from(pid);
}


} // namespace toit

#endif // TOIT_LINUX
