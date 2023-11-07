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

#include <algorithm>
#include <errno.h>

#include "top.h"
#include "flags.h"
#include "process.h"
#include "flash_registry.h"
#include "interpreter.h"
#include "scheduler.h"
#include "vm.h"
#include "os.h"
#include "snapshot.h"
#include "third_party/dartino/gc_metadata.h"

namespace toit {

static void print_usage(int exit_code) {
  // We don't expose the `--lsp` flag in the help. It's internal and not
  // relevant for users.
  printf("Usage:\n");
  printf("vm\n");
  printf("  [-h] [--help]                             // This help message\n");
  printf("  [--version]                               // Prints version information\n");
  printf("  [-X<flag>]*                               // Provide a compiler flag\n");
  printf("  image_file                                // The image file to be run\n");
  exit(exit_code);
}

static int run_program(Program* program) {
  while (true) {
    Scheduler::ExitState exit;
    {
      VM vm;
      vm.load_platform_event_sources();
      int group_id = vm.scheduler()->next_group_id();
      exit = vm.scheduler()->run_boot_program(program, null, group_id);
    }
    switch (exit.reason) {
      case Scheduler::EXIT_NONE:
        UNREACHABLE();

      case Scheduler::EXIT_DONE:
        return 0;

      case Scheduler::EXIT_ERROR:
        return exit.value;

      case Scheduler::EXIT_DEEP_SLEEP: {
        struct timespec sleep_time;
        sleep_time.tv_sec = exit.value / 1000;
        sleep_time.tv_nsec = (exit.value % 1000) * 1000000;

        while (nanosleep(&sleep_time, &sleep_time) != 0 && errno == EINTR) {}
        break;
      }
    }
  }
}

int main(int argc, char **argv) {
  Flags::process_args(&argc, argv);
  if (argc < 2) print_usage(1);

  FlashRegistry::set_up();
  OS::set_up();
  ObjectMemory::set_up();

  char* image_filename = argv[1];
  Flags::program_name = image_filename;
  FILE* file = fopen(image_filename, "rb");
  if (file == null) {
    FATAL("Couldn't open file");
  }
  fseek(file, 0, SEEK_END);
  auto image_size = ftell(file);
  fseek(file, 0, SEEK_SET);
  ASSERT(image_size % (WORD_BIT_SIZE + 1) == 0);
  // We use one word for the following WORD_BIT_SIZE words as relocation bits.
  int relocated_size = (image_size / (WORD_BIT_SIZE + 1)) * WORD_BIT_SIZE;
  auto relocated_memory = _new AlignedMemory(relocated_size, TOIT_PAGE_SIZE);
  ProgramImage relocated(relocated_memory->address(), relocated_size);
  ImageOutputStream output(relocated);

  const int CHUNK_WORD_SIZE = WORD_BIT_SIZE + 1;
  int image_word_size = image_size / WORD_SIZE;
  for (int i = 0; i < image_word_size; i += CHUNK_WORD_SIZE) {
    word buffer[CHUNK_WORD_SIZE];
    int end = std::min(i + CHUNK_WORD_SIZE, image_word_size);
    int chunk_word_size = end - i;
    int read_words = fread(buffer, WORD_SIZE, chunk_word_size, file);
    if (chunk_word_size != read_words) {
      FATAL("Problems reading the image");
    }
    output.write(reinterpret_cast<word*>(buffer), chunk_word_size);
  }
  fclose(file);

  int exit_state = run_program(reinterpret_cast<Program*>(relocated.program()));

  GcMetadata::tear_down();
  OS::tear_down();
  FlashRegistry::tear_down();
  return exit_state;
}

} // namespace toit

int main(int argc, char** argv) {
  return toit::main(argc, argv);
}
