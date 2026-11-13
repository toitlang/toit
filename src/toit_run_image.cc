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
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "top.h"
#include "flags.h"
#include "process.h"
#include "flash_registry.h"
#include "interpreter.h"
#include "main_utf_8_helper.h"
#include "messaging.h"
#include "scheduler.h"
#include "vm.h"
#include "os.h"
#include "snapshot.h"
#include "third_party/dartino/gc_metadata.h"

extern "C" {
  extern unsigned char run_image_image[];
  extern unsigned int run_image_image_len;
};

namespace toit {

static int run_program(Program* program, char** argv) {
  while (true) {
    Scheduler::ExitState exit;
    {
      VM vm;
      vm.load_platform_event_sources();
      create_and_start_external_message_handlers(&vm);
      int group_id = vm.scheduler()->next_group_id();
      exit = vm.scheduler()->run_boot_program(program, argv, group_id);
    }
    switch (exit.reason) {
      case Scheduler::EXIT_NONE:
        UNREACHABLE();

      case Scheduler::EXIT_DONE:
        return 0;

      case Scheduler::EXIT_ERROR:
        return exit.value;

      case Scheduler::EXIT_RESET:
        break;

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

// Firmware that has programs combined with the system program has its own
// system image. The firmware tool puts it with the startup images, so
// firmware updates that are written by older firmware carry it along.
// Returns null if there is none.
static uint8* read_system_image(const char* ota_dir, unsigned int* size) {
  // The VM doesn't allow allocations that throw, like the ones of std::string.
  static const char* const NAME = "/startup-images/system";
  size_t path_size = strlen(ota_dir) + strlen(NAME) + 1;
  char* path = static_cast<char*>(malloc(path_size));
  if (path == null) FATAL("Out of memory");
  snprintf(path, path_size, "%s%s", ota_dir, NAME);
  FILE* file = fopen(path, "rb");
  if (file == null) {
    free(path);
    return null;
  }
  uint8* result = null;
  if (fseek(file, 0, SEEK_END) == 0) {
    long length = ftell(file);
    if (length > 0 && fseek(file, 0, SEEK_SET) == 0) {
      // Allocated with malloc, so it is aligned for words.
      result = static_cast<uint8*>(malloc(length));
      if (result != null && fread(result, 1, length, file) != static_cast<size_t>(length)) {
        free(result);
        result = null;
      }
      *size = static_cast<unsigned int>(length);
    }
  }
  fclose(file);
  if (result == null) FATAL("Couldn't read the system image %s", path);
  free(path);
  return result;
}

int main(int argc, char **argv) {
  FlashRegistry::set_up();
  OS::set_up();
  ObjectMemory::set_up();

  uint8* image = run_image_image;
  unsigned int image_size = run_image_image_len;
  uint8* system_image = argc >= 2 ? read_system_image(argv[1], &image_size) : null;
  if (system_image != null) image = system_image;
  if (image_size % WORD_SIZE != 0) FATAL("Invalid system image");
  // We use one word for the following WORD_BIT_SIZE words as relocation bits.
  int relocated_size = (image_size / (WORD_BIT_SIZE + 1)) * WORD_BIT_SIZE;
  auto relocated_memory = _new AlignedMemory(relocated_size, TOIT_PAGE_SIZE);
  ProgramImage relocated(relocated_memory->address(), relocated_size);
  ImageOutputStream output(relocated);

  const int CHUNK_WORD_SIZE = WORD_BIT_SIZE + 1;
  int image_word_size = image_size / WORD_SIZE;
  for (int i = 0; i < image_word_size; i += CHUNK_WORD_SIZE) {
    int end = std::min(i + CHUNK_WORD_SIZE, image_word_size);
    int chunk_word_size = end - i;
    output.write(reinterpret_cast<word*>(&image[i * WORD_SIZE]), chunk_word_size);
  }
  free(system_image);

  int exit_state = run_program(reinterpret_cast<Program*>(relocated.program()), &argv[1]);

  GcMetadata::tear_down();
  OS::tear_down();
  FlashRegistry::tear_down();
  return exit_state;
}

} // namespace toit

int main(int argc, char** argv) {
  return run_with_utf_8_args(toit::main, argc, argv);
}
