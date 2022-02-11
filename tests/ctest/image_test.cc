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

#include <vector>
#ifndef WIN32
  #include <sys/mman.h>
#endif
#include <stdio.h>
#include <string>

#include "../../src/compiler/compiler.h"
#include "../../src/flags.h"
#include "../../src/snapshot.h"
#include "../../src/os.h"

#ifdef WIN32
#define PROT_READ 0
#define PROT_WRITE 1
int mprotect(void* addr, size_t len, int prot) {
  UNIMPLEMENTED();
}
#endif

namespace toit {

static SnapshotBundle compile(const char* input_path) {
  Flags::no_fork = true;
  char** args = null;
  const char* out_path = null;

  compiler::Compiler compiler;  // Make sure we destroy the compiler before we attempt to run anything.
  return compiler.compile(input_path,
                          null,
                          args,
                          out_path, {
                            .dep_file = null,
                            .dep_format = compiler::Compiler::DepFormat::none,
                            .project_root = null,
                            .force = false,
                            .werror = true,
                          });
}

static ProgramImage anchored_to_relocatable(ProgramImage anchored) {
  auto relocation_bits = ImageInputStream::build_relocation_bits(anchored);
  ImageInputStream input(anchored, relocation_bits);

  std::vector<char> relocatable_bytes;
  while (!input.eos()) {
    int buffer_size_in_words = input.words_to_read();
    word buffer[buffer_size_in_words];
    int words = input.read(buffer);
    uint8* buffer_uint8 = reinterpret_cast<uint8*>(buffer);
    relocatable_bytes.insert(relocatable_bytes.end(), buffer_uint8, &buffer_uint8[words * WORD_SIZE]);
  }
  auto relocatable_data = unvoid_cast<uint8*>(malloc(relocatable_bytes.size()));
  memcpy(relocatable_data, relocatable_bytes.data(), relocatable_bytes.size());
  return ProgramImage(relocatable_data, relocatable_bytes.size());
}

static void relocatable_to_exploded(ProgramImage relocatable,
                                    AlignedMemory** anchored_memory,
                                    int* anchored_size) {
  ASSERT(relocatable.byte_size() % (WORD_BIT_SIZE + 1) == 0);
  // We use one word for the following WORD_BIT_SIZE words as relocation bits.
  *anchored_size = (relocatable.byte_size() / (WORD_BIT_SIZE + 1)) * WORD_BIT_SIZE;
  *anchored_memory = _new AlignedMemory(*anchored_size, TOIT_PAGE_SIZE);
  ProgramImage anchored((*anchored_memory)->address(), *anchored_size);
  ImageOutputStream output(anchored);

  const int CHUNK_WORD_SIZE = WORD_BIT_SIZE + 1;
  int image_word_size = relocatable.byte_size() / WORD_SIZE;
  for (int i = 0; i < image_word_size; i += CHUNK_WORD_SIZE) {
    word buffer[CHUNK_WORD_SIZE];
    int end = std::min(i + CHUNK_WORD_SIZE, image_word_size);
    int chunk_word_size = end - i;
    memcpy(buffer, &relocatable.begin()[i], chunk_word_size * WORD_SIZE);
    output.write(reinterpret_cast<word*>(buffer), chunk_word_size);
  }
}

int main(int argc, char** argv) {
  if (argc != 2) FATAL("wrong number of arguments");
  throwing_new_allowed = true;
  OS::set_up();

  auto compiled = compile(argv[1]);
  // Compiler resets it in its descructor.
  throwing_new_allowed = true;

  const uint8* bytecodes = compiled.snapshot().buffer();
  int bytecodes_size = compiled.snapshot().size();

  // Take the snapshot and "extract" it in some aligned memory.
  auto anchored_image = compiled.snapshot().read_image();

  {
    // Check that we get the same snapshot after having exploded it.
    auto program = reinterpret_cast<Program*>(anchored_image.address());
    SnapshotGenerator generator(program);
    generator.generate(program);
    if (generator.the_length() != bytecodes_size) FATAL("not same size");
    if (memcmp(generator.the_buffer(), bytecodes, generator.the_length()) != 0) FATAL("not equal");
  }

  // Transform it to be position independent.
  ProgramImage relocatable = anchored_to_relocatable(anchored_image);
  // Try again, to verify that the two don't differ.
  ProgramImage relocatable2 = anchored_to_relocatable(anchored_image);

  if (relocatable.byte_size() != relocatable2.byte_size()) FATAL("not same size");
  if (memcmp(relocatable.begin(), relocatable2.begin(), relocatable.byte_size()) != 0) FATAL("not equal");

  // Relocate the position-independent code.
  AlignedMemory* relocated_memory;
  int relocated_size;
  relocatable_to_exploded(relocatable, &relocated_memory, &relocated_size);

  // Garble the exploded images, so that the relocated memory can't accidentally read
  // from them.
  memset(relocatable.begin(), 0xbc, relocatable.byte_size());
  memset(relocatable2.begin(), 0xbc, relocatable2.byte_size());

  // We are normally not allowed to write into program memory.
  // Remove the protection.
  int status = mprotect(anchored_image.address(), anchored_image.byte_size(), PROT_READ | PROT_WRITE);
  if (status != 0) {
    perror("mark writable");
    exit(1);
  }

  memset(anchored_image.address(), 0xbc, anchored_image.byte_size());
  {
    // Check that we get the same bytecodes after having relocated the image.
    auto program = reinterpret_cast<Program*>(relocated_memory->address());
    SnapshotGenerator generator(program);
    generator.generate(program);
    if (generator.the_length() != bytecodes_size) FATAL("not same size");
    if (memcmp(generator.the_buffer(), bytecodes, generator.the_length()) != 0) FATAL("not equal");
  }

  free(compiled.buffer());
  anchored_image.release();
  delete relocated_memory;
  return 0;
}

}

int main(int argc, char** argv) {
  return toit::main(argc, argv);
}
