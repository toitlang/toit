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
  if (offset < 0 || offset + byte_size > FlashRegistry::allocations_size()) OUT_OF_BOUNDS;

  ByteArray* result = process->object_heap()->allocate_proxy();
  if (result == null) ALLOCATION_FAILED;

  if (!FlashRegistry::erase_chunk(offset, byte_size)) HARDWARE_ERROR;
  void* address = FlashRegistry::memory(offset, byte_size);
  ProgramImage image(address, byte_size);
  ImageOutputStream* output = _new ImageOutputStream(image);
  if (output == null) MALLOC_FAILED;

  result->set_external_address(output);
  return result;
}

static bool write_image_chunk(ImageOutputStream* output, const word* data, int length) {
  int output_byte_size = (length - 1) * WORD_SIZE;  // The first word is relocation bits, not part of the output.
  word buffer[WORD_BIT_SIZE];

  bool first = output->empty();
  int offset = FlashRegistry::offset(output->cursor());
  if (offset < 0 || offset + output_byte_size > FlashRegistry::allocations_size()) {
    // TODO(kasper): Should be OUT_OF_BOUNDS.
    return false;
  }
  output->write(data, length, buffer);

  if (first) {
    // Do not write the program header just yet.
    const int header_size = sizeof(Program::Header);
    ASSERT(Utils::is_aligned(header_size, WORD_SIZE));
    const int header_words = header_size / WORD_SIZE;
    return FlashRegistry::write_chunk(&buffer[header_words], offset + header_size, output_byte_size - header_size);
  } else {
    return FlashRegistry::write_chunk(buffer, offset, output_byte_size);
  }
}

PRIMITIVE(writer_write) {
  ARGS(ImageOutputStream, output, Blob, content_bytes, int, from, int, to);
  if (to < from || from < 0) INVALID_ARGUMENT;
  if (to > content_bytes.length()) OUT_OF_BOUNDS;
  const word* data = reinterpret_cast<const word*>(content_bytes.address() + from);
  int length = (to - from) / WORD_SIZE;
  if (!write_image_chunk(output, data, length)) HARDWARE_ERROR;
  return process->program()->null_object();
}

PRIMITIVE(writer_write_all) {
  ARGS(ImageOutputStream, output, int, from, int, to);
  while (from < to) {
    const word* data = unvoid_cast<const word*>(FlashRegistry::memory(from, to - from));
    int length = Utils::min((to - from) / WORD_SIZE, WORD_BIT_SIZE + 1);
    if (!write_image_chunk(output, data, length)) HARDWARE_ERROR;
    from += length * WORD_SIZE;
  }
  return process->program()->null_object();
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
  if (FlashAllocation::initialize(header_offset, PROGRAM_TYPE, id_bytes.address(), image.byte_size(), meta_data)) {
    return process->program()->null_object();
  }
  HARDWARE_ERROR;
}

PRIMITIVE(writer_close) {
  ARGS(ImageOutputStream, output);
  delete output;
  output_proxy->clear_external_address();
  return process->program()->null_object();
}

} // namespace toit
