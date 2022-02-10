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

#include "../../src/top.h"
#include "../../src/scheduler.h"
#include "../../src/flash_registry.h"
#include "../../src/compiler/compiler.h"
#include "../../src/flags.h"
#include "../../src/snapshot.h"
#include "../../src/os.h"

namespace toit {

unsigned int checksum[4] = { 0, 0, 0, 0 };

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

class MessageHandler : public ExternalSystemMessageHandler {
 public:
  MessageHandler(VM* vm) : ExternalSystemMessageHandler(vm) { }
  virtual void on_message(int sender, int type, void* data, int length);
};

void MessageHandler::on_message(int sender, int type, void* data, int length) {
  send(sender, type, data, length);
}

int run_program(Snapshot snapshot) {
  VM vm;
  vm.load_platform_event_sources();
  auto image = snapshot.read_image();
  int group_id = vm.scheduler()->next_group_id();

  MessageHandler handler(&vm);
  handler.start();

  Scheduler::ExitState exit = vm.scheduler()->run_boot_program(image.program(), NULL, group_id);
  image.release();

  switch (exit.reason) {
    case Scheduler::EXIT_DONE:
      return 0;
    case Scheduler::EXIT_ERROR:
      return exit.value;
    default:
      FATAL("unexpected exit reason: %d", exit.reason);
  }
}

int main(int argc, char **argv) {
  Flags::process_args(&argc, argv);
  if (argc != 2) FATAL("wrong number of arguments");

  FlashRegistry::set_up();
  OS::set_up();

  auto compiled = compile(argv[1]);
  int result = run_program(compiled.snapshot());
  free(compiled.buffer());

  OS::tear_down();
  FlashRegistry::tear_down();
  return result;
}

} // namespace toit

int main(int argc, char** argv) {
  return toit::main(argc, argv);
}
