// Copyright (C) 2026 Toit contributors.
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

// Entry point for the WebAssembly build of the Toit VM.
//
// WebAssembly (in the browser, and in Node.js without workers) has no
// threads, and the main thread must never block. The VM therefore doesn't
// sit in a loop waiting for processes to complete. Instead, it runs
// processes in small steps that are scheduled on the JavaScript event loop:
// every step dispatches the pending events (timers, ...) and then runs
// ready processes until they are all idle or the step's time budget is used
// up. If processes are still ready, the next step is scheduled immediately;
// otherwise it is scheduled for when the next timer expires.

#include "top.h"

#ifdef TOIT_WASM

#include <emscripten.h>
#include <emscripten/eventloop.h>

#include "flags.h"
#include "flash_registry.h"
#include "messaging.h"
#include "os.h"
#include "process.h"
#include "resource.h"
#include "scheduler.h"
#include "snapshot_bundle.h"
#include "vm.h"
#include "event_sources/js_wasm.h"
#include "third_party/dartino/gc_metadata.h"

#include "objects_inline.h"

extern "C" {
  extern unsigned char toit_run_snapshot[];
  extern unsigned int toit_run_snapshot_len;
};

namespace toit {

// The maximum time a step runs Toit code before it returns to the
// JavaScript event loop. Keeping it short keeps the browser responsive.
static const int64 STEP_BUDGET_US = 20 * 1000;

static ProgramImage read_image_from_bundle(SnapshotBundle bundle) {
  if (!bundle.is_valid()) return ProgramImage::invalid();
  uint8 buffer[UUID_SIZE];
  uint8* id = bundle.uuid(buffer) ? buffer : null;
  return bundle.snapshot().read_image(id);
}

class WasmRunner {
 public:
  // Takes over the bundles.
  WasmRunner(SnapshotBundle boot_bundle, SnapshotBundle application_bundle, char** argv)
      : boot_bundle_(boot_bundle)
      , application_bundle_(application_bundle)
      , argv_(argv) {}

  // Boots the VM and schedules the first step.
  void start();

  // Schedules a step. If a step is already scheduled for a later time,
  // it is rescheduled.
  void schedule_step(int64 delay_us);

 private:
  SnapshotBundle boot_bundle_;
  SnapshotBundle application_bundle_;
  char** argv_;

  VM* vm_ = null;
  ProgramImage boot_image_ = ProgramImage::invalid();
  ProgramImage application_image_ = ProgramImage::invalid();

  // The id of the scheduled step callback and the time (in
  // OS::get_system_time microseconds) it is scheduled for.
  long scheduled_id_ = 0;
  bool scheduled_is_immediate_ = false;
  int64 scheduled_time_ = -1;

  static void step_callback(void* data);
  void step();
  void cancel_scheduled_step();
  void terminated();
};

void WasmRunner::start() {
  vm_ = _new VM();
  vm_->load_platform_event_sources();
  create_and_start_external_message_handlers(vm_);
  int group_id = vm_->scheduler()->next_group_id();
  boot_image_ = read_image_from_bundle(boot_bundle_);
  if (boot_image_.is_valid()) {
    // The boot program is the system program. It launches the application
    // that is passed to it in the spawn arguments.
    vm_->scheduler()->start_boot_program(
        boot_image_.program(), boot_bundle_, application_bundle_, argv_, group_id);
  } else {
    // Without a system program, the application runs as boot program.
    application_image_ = read_image_from_bundle(application_bundle_);
    vm_->scheduler()->start_boot_program(application_image_.program(), argv_, group_id);
  }
  schedule_step(0);
}

void WasmRunner::step_callback(void* data) {
  WasmRunner* runner = static_cast<WasmRunner*>(data);
  runner->scheduled_id_ = 0;
  runner->scheduled_time_ = -1;
  runner->step();
}

void WasmRunner::cancel_scheduled_step() {
  if (scheduled_id_ == 0) return;
  if (scheduled_is_immediate_) {
    emscripten_clear_immediate(scheduled_id_);
  } else {
    emscripten_clear_timeout(scheduled_id_);
  }
  scheduled_id_ = 0;
  scheduled_time_ = -1;
}

void WasmRunner::schedule_step(int64 delay_us) {
  int64 time = OS::get_system_time() + delay_us;
  if (scheduled_id_ != 0) {
    if (scheduled_time_ <= time) return;
    cancel_scheduled_step();
  }
  scheduled_time_ = time;
  scheduled_is_immediate_ = delay_us <= 0;
  if (scheduled_is_immediate_) {
    scheduled_id_ = emscripten_set_immediate(step_callback, this);
  } else {
    scheduled_id_ = emscripten_set_timeout(step_callback, delay_us / 1000.0, this);
  }
}

void WasmRunner::step() {
  Scheduler* scheduler = vm_->scheduler();
  int64 deadline = OS::get_monotonic_time() + STEP_BUDGET_US;
  while (true) {
    int64 now = OS::get_system_time();
    int64 next_event = vm_->event_manager()->poll(now);
    if (!scheduler->has_ready_processes()) {
      // All processes are idle. Wait for the next timed event. Events
      // that aren't timed (from JavaScript) schedule a step themselves.
      if (next_event >= 0) schedule_step(Utils::max(next_event - now, static_cast<int64>(0)));
      return;
    }
    if (OS::get_monotonic_time() >= deadline) {
      // Give the JavaScript event loop a chance to run.
      schedule_step(0);
      return;
    }
    if (!scheduler->run_next(deadline)) {
      terminated();
      return;
    }
  }
}

void WasmRunner::terminated() {
  cancel_scheduled_step();
  Scheduler::ExitState exit_state = vm_->scheduler()->finish();
  delete vm_;
  vm_ = null;
  boot_image_.release();
  application_image_.release();

  // Force the exit, even if JavaScript still holds on to the runtime (for
  // example because main left with emscripten_exit_with_live_runtime).
  // This shuts down the runtime, flushing stdout and stderr, and notifies
  // the embedder through Module.onExit.
  switch (exit_state.reason) {
    case Scheduler::EXIT_NONE:
      UNREACHABLE();

    case Scheduler::EXIT_DONE:
      emscripten_force_exit(0);

    case Scheduler::EXIT_ERROR:
      emscripten_force_exit(static_cast<int>(exit_state.value));

    case Scheduler::EXIT_RESET:
    case Scheduler::EXIT_DEEP_SLEEP:
      // TODO(florian): restart the boot program. The bundles have been
      // handed over to the system process, which frees them.
      emscripten_force_exit(0);
  }
}

static WasmRunner* runner = null;

// Called from JavaScript (src/wasm/library_toit.js) when a call to a
// JavaScript function has completed. Takes over the malloced result.
extern "C" EMSCRIPTEN_KEEPALIVE
void toit_js_call_complete(word id, uint8* result, word length, int is_error) {
  JsEventSource* event_source = JsEventSource::instance();
  if (event_source == null) {
    // The VM has already terminated.
    free(result);
    return;
  }
  event_source->complete(id, result, length, is_error != 0);
  // The completion may have made a process ready.
  runner->schedule_step(0);
}

static void print_usage(int exit_code) {
  printf("Usage:\n");
  printf("toit.wasm <snapshot> <args>...\n");
  exit(exit_code);
}

int main(int argc, char** argv) {
  Flags::process_args(&argc, argv);
  if (argc < 2) print_usage(1);

  FlashRegistry::set_up();
  OS::set_up();
  ObjectMemory::set_up();

  char* bundle_path = argv[1];
  Flags::program_name = bundle_path;
  Flags::program_path = OS::get_executable_path_from_arg(bundle_path);
  auto application_bundle = SnapshotBundle::read_from_file(bundle_path);
  if (!application_bundle.is_valid()) print_usage(1);

  // The boot bundle is handed over to the system process, which frees it
  // as part of an external byte array.
  auto boot_copy = unvoid_cast<uint8*>(malloc(toit_run_snapshot_len));
  if (boot_copy == null) FATAL("unable to allocate boot snapshot");
  memcpy(boot_copy, toit_run_snapshot, toit_run_snapshot_len);
  SnapshotBundle boot_bundle(boot_copy, toit_run_snapshot_len);

  runner = _new WasmRunner(boot_bundle, application_bundle, &argv[2]);
  runner->start();

  // Leave main without shutting down the runtime. The scheduled steps
  // keep it alive.
  emscripten_exit_with_live_runtime();
  return 0;
}

} // namespace toit

int main(int argc, char** argv) {
  return toit::main(argc, argv);
}

#endif  // TOIT_WASM
