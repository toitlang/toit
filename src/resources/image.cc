// Copyright (C) 2018 Toitware ApS.
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
#include "../objects_inline.h"
#include "../primitive.h"
#include "../process.h"
#include "../os.h"
#include "../flash_registry.h"

namespace toit {

MODULE_IMPLEMENTATION(image, MODULE_IMAGE)

PRIMITIVE(writer_create) {
  ARGS(int, offset, int, byte_size);
  ByteArray* result = process->object_heap()->allocate_proxy();
  if (result == null) ALLOCATION_FAILED;

  FlashRegistry::erase_chunk(offset, byte_size);
  void* address = FlashRegistry::memory(offset, byte_size);
  ProgramImage image(address, byte_size);
  ImageOutputStream* output = _new ImageOutputStream(image);
  if (output == null) MALLOC_FAILED;

  result->set_external_address(output);
  return result;
}

PRIMITIVE(writer_write) {
  ARGS(ImageOutputStream, output, Blob, content_bytes, int, from, int, to);

  word buffer[WORD_BIT_SIZE];

  int length = (to - from) / WORD_SIZE;
  //TODO(florian): the size of the content_bytes is ignored. We should probably add checks.
  const word* data = reinterpret_cast<const word*>(content_bytes.address() + from);

  bool first = output->empty();
  int offset = FlashRegistry::offset(output->cursor());
  output->write(data, length, buffer);

  bool success = false;
  if (first) {
    // Do not write the program header just yet.
    const int header_size = sizeof(Program::Header);
    ASSERT(Utils::is_aligned(header_size, WORD_SIZE));
    const int header_words = header_size / WORD_SIZE;
    success = FlashRegistry::write_chunk(&buffer[header_words], offset + header_size, (length - header_words - 1) * WORD_SIZE);
  } else {
    success = FlashRegistry::write_chunk(buffer, offset, (length - 1) * WORD_SIZE);
  }

  if (success) return process->program()->null_object();
  OUT_OF_BOUNDS;
}

PRIMITIVE(writer_commit) {
  ARGS(ImageOutputStream, output, Blob, id_bytes);

  ProgramImage image = output->image();
  if (!image.is_valid() || output->cursor() != image.end()) OUT_OF_BOUNDS;

  // Write program header as the last thing. Only a complete flash write
  // will mark the program as valid.
  int header_offset = FlashRegistry::offset(image.begin());
  uint8 meta_data[FlashAllocation::Header::meta_data_size()];
  memset(meta_data, 0, FlashAllocation::Header::meta_data_size());
  if (FlashAllocation::initialize(header_offset, PROGRAM_TYPE, id_bytes.address(), image.byte_size(), meta_data))
    return process->program()->null_object();
  OUT_OF_BOUNDS;
}

PRIMITIVE(writer_close) {
  ARGS(ImageOutputStream, output);
  delete output;
  output_proxy->clear_external_address();
  return process->program()->null_object();
}

} // namespace toit
