// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Without a boot process, Scheduler::send_system_message handles the
// life-cycle messages (TERMINATED and SPAWNED) itself, and nobody handles
// the other system messages. Processes can still send them in that state:
// when the boot process terminates, the other processes keep running until
// the scheduler stops them, and process_send sends any message type to the
// system (negative pid). The core library does so on its own when it
// reports an uncaught exception. The scheduler must drop these messages
// instead of aborting the VM.

#include <stdlib.h>

#include "../../src/top.h"
#include "../../src/flash_registry.h"
#include "../../src/messaging.h"
#include "../../src/third_party/dartino/object_memory.h"
#include "../../src/os.h"
#include "../../src/scheduler.h"
#include "../../src/vm.h"

namespace toit {

static SystemMessage* new_message(int type) {
  uint8* data = unvoid_cast<uint8*>(malloc(MESSAGING_PROCESS_MESSAGE_SIZE));
  if (data == null) FATAL("malloc failed");
  MessageEncoder::encode_process_message(data, 0);
  SystemMessage* message = _new SystemMessage(type, 0, 1, data);  // Takes over data.
  if (message == null) FATAL("allocation failed");
  return message;
}

static void run() {
  VM vm;
  Scheduler* scheduler = vm.scheduler();
  // No boot program is running, so there is no boot process.
  const int types[] = {
    SYSTEM_SPAWNED,
    SYSTEM_TRACE,
    SYSTEM_RPC_REQUEST,
    SYSTEM_RPC_REPLY,
    SYSTEM_RPC_CANCEL,
    SYSTEM_RPC_NOTIFY_TERMINATED,
    SYSTEM_RPC_NOTIFY_RESOURCE,
    SYSTEM_EXTERNAL_NOTIFICATION,
    63,
    64,
    1000,
  };
  for (int type : types) {
    // Takes over the message.
    message_err_t result = scheduler->send_system_message(new_message(type));
    if (result != MESSAGE_OK) FATAL("type %d: unexpected result %d", type, result);
  }
}

}  // namespace toit

int main(int argc, char** argv) {
  toit::FlashRegistry::set_up();
  toit::OS::set_up();
  toit::ObjectMemory::set_up();
  toit::run();
  toit::ObjectMemory::tear_down();
  toit::OS::tear_down();
  toit::FlashRegistry::tear_down();
  return 0;
}
