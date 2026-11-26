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
#include "../out_of_memory.h"
#include "../flash_registry.h"
#include "../verifier_v2.h"

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
  // The system process writes an image for a client: an allocation failure
  // fails the request (ContainerServiceProvider.image-writer-open) instead
  // of restarting the device. A failed call leaves nothing behind (the
  // erased pages are reserved).
  process->object_heap()->set_allocation_failure_recoverable();
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
  // The content must consist of whole words: a word of relocation bits,
  // followed by at most one word per relocation bit. The words don't
  // need to be aligned; they are read with unaligned reads.
  if (!Utils::is_aligned(to - from, WORD_SIZE)) FAIL(INVALID_ARGUMENT);
  word length = (to - from) / WORD_SIZE;
  if (length < 2 || length > ImageOutputStream::CHUNK_SIZE) FAIL(INVALID_ARGUMENT);
  const word* data = reinterpret_cast<const word*>(content_bytes.address() + from);
  Object* error = write_image_chunk(process, output, data, length);
  return error ? error : process->null_object();
}

PRIMITIVE(writer_commit) {
  ARGS(ImageOutputStream, output, Blob, metadata_blob);
  // As writer_create. The allocations come before the header is written
  // (the error message of a verdict), so a failed call commits nothing.
  process->object_heap()->set_allocation_failure_recoverable();
  if (inject_system_allocation_failure(process, "commit")) FAIL(ALLOCATION_FAILED);
  uint8 metadata[FlashAllocation::Header::METADATA_SIZE];
  if (metadata_blob.length() != sizeof(metadata)) FAIL(INVALID_ARGUMENT);
  memcpy(metadata, metadata_blob.address(), sizeof(metadata));

  ProgramImage image = output->image();
  if (!image.is_valid() || output->cursor() != image.end()) FAIL(OUT_OF_BOUNDS);

  // If there are extra bytes after the program, they represent assets associated
  // with the program image. Check that the size of the encoded assets is within
  // bounds and mark the metadata to indicate the presence of the assets.
  word program_size = output->program_size();
  bool has_assets = false;
  word allocation_size = FlashAllocation::image_allocation_size(
      image.begin(), program_size, image.end(), &has_assets);
  if (allocation_size < 0) FAIL(OUT_OF_BOUNDS);
  if (has_assets) {
    // TODO(kasper): Can we get the metadata to already contain the right bits
    // from the get go? Right now, we ignore the bits put in there when
    // converting from snapshot to image, but that seems fishy.
    metadata[0] |= FlashAllocation::Header::FLAGS_PROGRAM_HAS_ASSETS_MASK;
  }

  // A shipped certificate (format 2 note 18) may follow the allocation as a
  // trailing block. It is not part of the allocation.
  uword allocation_end = reinterpret_cast<uword>(image.begin()) + allocation_size;
  const uint8* certificate = null;
  word certificate_length = 0;
  FlashAllocation::find_certificate_block(reinterpret_cast<void*>(allocation_end), image.end(),
                                          &certificate, &certificate_length);

  // Install-time verification of images flagged untrusted (Phase 5): every
  // byte of the program is written; the verdict goes into the metadata and
  // the header's checksum binds it to the bytes (flash_allocation.h). A
  // rejected image is not committed.
  const char* error = V2Verifier::install_verdict(image.begin(), program_size, metadata,
                                                  certificate, certificate_length, process);
  if (error == V2Verifier::OUT_OF_MEMORY && !process->object_heap()->retrying_primitive()) {
    // Collect every process's garbage and retry once (nothing is written
    // before the verdict).
    FAIL(CROSS_PROCESS_GC);
  }
  if (error != null) {
    String* message = process->allocate_string(error);
    if (message == null) FAIL(ALLOCATION_FAILED);
    return Error::from(message);
  }

  // Drop the pages after the allocation (the certificate block): it has
  // served its purpose, and the pages become a hole once the reservation
  // is closed (system/flash/image_writer.toit gives them back to the
  // registry). Erased before the header is written, so a valid allocation
  // never has a certificate behind it.
  word tail = image.byte_size() - allocation_size;
  if (tail > 0) {
    word tail_offset = FlashRegistry::offset(reinterpret_cast<void*>(allocation_end));
    if (!FlashRegistry::erase_chunk(tail_offset, tail)) FAIL(HARDWARE_ERROR);
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
