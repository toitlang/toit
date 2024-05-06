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

PRIMITIVE(current_id) {
  const uint8* id = process->program()->id();
  ByteArray* result = process->object_heap()->allocate_external_byte_array(
      Program::Header::ID_SIZE, const_cast<uint8*>(id), false, false);
  if (!result) FAIL(ALLOCATION_FAILED);
  return result;
}

PRIMITIVE(writer_create) {
  ARGS(int, offset, int, byte_size);
  if (offset < 0 || offset + byte_size > FlashRegistry::allocations_size()) FAIL(OUT_OF_BOUNDS);

  ByteArray* result = process->object_heap()->allocate_proxy();
  if (result == null) FAIL(ALLOCATION_FAILED);

  if (!FlashRegistry::erase_chunk(offset, byte_size)) FAIL(HARDWARE_ERROR);
  void* address = FlashRegistry::region(offset, byte_size);
  ProgramImage image(address, byte_size);
  ImageOutputStream* output = _new ImageOutputStream(image);
  if (output == null) FAIL(MALLOC_FAILED);

  result->set_external_address(output);
  return result;
}

static Object* write_image_chunk(Process* process, ImageOutputStream* output, const word* data, word length) {
  // The first word is relocation bits, not part of the output.
  word output_byte_size = (length - 1) * WORD_SIZE;
  word buffer[WORD_BIT_SIZE];

  bool first = output->empty();
  word offset = FlashRegistry::offset(output->cursor());
  if (offset < 0 || offset + output_byte_size > FlashRegistry::allocations_size()) FAIL(OUT_OF_BOUNDS);
  output->write(data, length, buffer);

  bool success = false;
  if (first) {
    // Do not write the program header just yet, but capture the program id
    // and size from there, so we can fill in the header later.
    Program::Header* header = reinterpret_cast<Program::Header*>(&buffer[0]);
    output->set_program_id(header->id());
    output->set_program_size(header->size());
    const word header_size = sizeof(Program::Header);
    ASSERT(Utils::is_aligned(header_size, WORD_SIZE));
    const word header_words = header_size / WORD_SIZE;
    success = FlashRegistry::write_chunk(&buffer[header_words], offset + header_size, output_byte_size - header_size);
  } else {
    success = FlashRegistry::write_chunk(buffer, offset, output_byte_size);
  }
  if (!success) FAIL(HARDWARE_ERROR);
  return null;
}

PRIMITIVE(writer_write) {
  ARGS(ImageOutputStream, output, Blob, content_bytes, word, from, word, to);
  if (to < from || from < 0) FAIL(INVALID_ARGUMENT);
  if (to > content_bytes.length()) FAIL(OUT_OF_BOUNDS);
  const word* data = reinterpret_cast<const word*>(content_bytes.address() + from);
  word length = (to - from) / WORD_SIZE;
  Object* error = write_image_chunk(process, output, data, length);
  return error ? error : process->null_object();
}

PRIMITIVE(writer_commit) {
  ARGS(ImageOutputStream, output, Blob, metadata_blob);
  uint8 metadata[FlashAllocation::Header::METADATA_SIZE];
  if (metadata_blob.length() != sizeof(metadata)) FAIL(INVALID_ARGUMENT);
  memcpy(metadata, metadata_blob.address(), sizeof(metadata));

  ProgramImage image = output->image();
  if (!image.is_valid() || output->cursor() != image.end()) FAIL(OUT_OF_BOUNDS);

  // If there are extra bytes after the program, they represent assets associated
  // with the program image. Check that the size of the encoded assets is within
  // bounds and mark the metadata to indicate the presence of the assets.
  uword program_size = output->program_size();
  uword assets_extra = image.byte_size() - program_size;
  if (assets_extra > 0) {
    uword assets_address = reinterpret_cast<uword>(image.begin()) + program_size;
    uword assets_length = *reinterpret_cast<uint32*>(assets_address);
    if (assets_length + sizeof(uint32) > assets_extra) FAIL(OUT_OF_BOUNDS);
    // TODO(kasper): Can we get the metadata to already contain the right bits
    // from the get go? Right now, we ignore the bits put in there when
    // converting from snapshot to image, but that seems fishy.
    metadata[0] |= FlashAllocation::Header::FLAGS_PROGRAM_HAS_ASSETS_MASK;
  }

  // Write program header as the last thing. Only a complete flash write
  // will mark the program as valid.
  const FlashAllocation::Header header(
      image.begin(),
      FLASH_ALLOCATION_TYPE_PROGRAM,
      output->program_id(),
      program_size,
      metadata);
  if (!FlashAllocation::commit(image.begin(), program_size, &header)) FAIL(HARDWARE_ERROR);
  return process->null_object();
}

PRIMITIVE(writer_close) {
  ARGS(ImageOutputStream, output);
  delete output;
  output_proxy->clear_external_address();
  return process->null_object();
}

} // namespace toit
