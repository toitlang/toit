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
  FlashRegistry::set_up();
  OS::set_up();
  ObjectMemory::set_up();

  auto image_size = run_image_image_len;
  ASSERT(image_size % (WORD_BIT_SIZE + 1) == 0);
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
    output.write(reinterpret_cast<word*>(&run_image_image[i * WORD_SIZE]), chunk_word_size);
  }

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
