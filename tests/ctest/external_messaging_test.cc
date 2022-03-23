// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include "../../src/top.h"
#include "../../src/scheduler.h"
#include "../../src/flash_registry.h"
#include "../../src/compiler/compiler.h"
#include "../../src/flags.h"
#include "../../src/snapshot.h"
#include "../../src/os.h"
#include "../../src/third_party/dartino/gc_metadata.h"

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

class MessageHandler : public ExternalSystemMessageHandler {
 public:
  explicit MessageHandler(VM* vm) : ExternalSystemMessageHandler(vm) { }
  virtual void on_message(int sender, int type, void* data, int length) override;


 private:
  bool _try_hard = false;
};

void MessageHandler::on_message(int sender, int type, void* data, int length) {
  collect_garbage(_try_hard);
  _try_hard = !_try_hard;

  if (!send(sender, type + 1, data, length, true)) {
    FATAL("unable to send");
  }
}


int run_program(Snapshot snapshot) {
  VM vm;
  vm.load_platform_event_sources();
  auto image = snapshot.read_image();
  int group_id = vm.scheduler()->next_group_id();

  MessageHandler handler(&vm);
  if (!handler.start()) {
    FATAL("unable to start handler");
  }

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
  GcMetadata::set_up();

  auto compiled = compile(argv[1]);
  int result = run_program(compiled.snapshot());
  free(compiled.buffer());

  GcMetadata::tear_down();
  OS::tear_down();
  FlashRegistry::tear_down();
  return result;
}

} // namespace toit

int main(int argc, char** argv) {
  return toit::main(argc, argv);
}
