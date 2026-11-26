// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Walks the processes' heap chunks (Scheduler::iterate_process_chunks, the
// walk of the out-of-memory heap report in os_esp32.cc) from another thread
// while the boot program spawns processes that terminate. The walk hands out
// copies of the owners' facts (pid, program id, system process), taken under
// the scheduler lock: the report used to keep the Process pointers and read
// their programs after the lock was released, which read a deleted process
// when one terminated meanwhile (LoadProhibited on a device). Under ASan the
// old shape of the walk reports a heap-use-after-free here.

#include <atomic>

#include "../../src/top.h"
#include "../../src/compiler/compiler.h"
#include "../../src/flags.h"
#include "../../src/flash_registry.h"
#include "../../src/os.h"
#include "../../src/scheduler.h"
#include "../../src/snapshot.h"
#include "../../src/uuid.h"
#include "../../src/vm.h"

namespace toit {

static const int MAX_OWNERS = 64;

struct WalkState {
  Scheduler::ProcessChunkOwner owners[MAX_OWNERS];
  int owner_count = 0;
  int chunks = 0;
  uword bytes = 0;
};

static void record_chunk(void* context, const Scheduler::ProcessChunkOwner* owner, uword address, uword size) {
  // Runs with the scheduler lock held: no allocation, no printing.
  auto state = static_cast<WalkState*>(context);
  state->chunks++;
  state->bytes += size;
  for (int i = 0; i < state->owner_count; i++) {
    if (state->owners[i].pid == owner->pid) return;
  }
  if (state->owner_count < MAX_OWNERS) state->owners[state->owner_count++] = *owner;
}

class WalkerThread : public Thread {
 public:
  WalkerThread(Scheduler* scheduler, const uint8* program_id)
      : Thread("walker"), scheduler_(scheduler) {
    memcpy(program_id_, program_id, UUID_SIZE);
  }

  void stop() { done_.store(true); }

  int walks() const { return walks_; }
  int children_seen() const { return children_seen_; }
  int max_owners() const { return max_owners_; }

 protected:
  void entry() override {
    while (!done_.load()) {
      WalkState state;
      scheduler_->iterate_process_chunks(&state, record_chunk);
      walks_++;
      // The facts are used after the lock is released, as the report
      // prints them: they are copies.
      int boot_processes = 0;
      for (int i = 0; i < state.owner_count; i++) {
        const Scheduler::ProcessChunkOwner& owner = state.owners[i];
        if (owner.pid < 0) FATAL("walk: invalid pid %d", owner.pid);
        if (memcmp(owner.program_id, program_id_, UUID_SIZE) != 0) {
          FATAL("walk: process %d has another program id", owner.pid);
        }
        if (owner.is_boot_process) {
          boot_processes++;
        } else {
          children_seen_++;
        }
      }
      if (boot_processes > 1) FATAL("walk: %d boot processes", boot_processes);
      if (state.owner_count > 0 && state.chunks < state.owner_count) FATAL("walk: owner without chunks");
      if (state.owner_count > max_owners_) max_owners_ = state.owner_count;
    }
  }

 private:
  Scheduler* scheduler_;
  uint8 program_id_[UUID_SIZE];
  std::atomic<bool> done_{false};
  int walks_ = 0;
  int children_seen_ = 0;
  int max_owners_ = 0;
};

}  // namespace toit

int main(int argc, char** argv) {
  using namespace toit;
  if (argc != 2) FATAL("expected fixture source");
  FlashRegistry::set_up();
  OS::set_up();
  ObjectMemory::set_up();
  Flags::no_fork = true;
  auto bundle = SnapshotBundle::invalid();
  {
    compiler::Compiler compiler;
    bundle = compiler.compile(argv[1], null, null, {
      .dep_file = null,
      .dep_format = compiler::Compiler::DepFormat::none,
      .project_root = null,
      .force = false,
      .werror = true,
    });
  }
  if (!bundle.is_valid()) FATAL("fixture compilation failed");
  int walks = 0;
  int children_seen = 0;
  int max_owners = 0;
  {
    VM vm;
    vm.load_platform_event_sources();
    auto image = bundle.snapshot().read_image(null);
    uint8 program_id[UUID_SIZE];
    memcpy(program_id, image.program()->id(), UUID_SIZE);
    WalkerThread walker(vm.scheduler(), program_id);
    if (!walker.spawn()) FATAL("cannot start the walker thread");
    char* arguments[] = {null};
    auto exit = vm.scheduler()->run_boot_program(image.program(), arguments,
                                                 vm.scheduler()->next_group_id());
    walker.stop();
    walker.join();
    image.release();
    if (exit.reason != Scheduler::EXIT_DONE) FATAL("fixture failed");
    walks = walker.walks();
    children_seen = walker.children_seen();
    max_owners = walker.max_owners();
  }
  printf("walks: %d, spawned processes seen: %d, most processes in one walk: %d\n",
         walks, children_seen, max_owners);
  if (walks == 0) FATAL("the walker never walked");
  if (children_seen == 0) FATAL("no walk overlapped a spawned process");
  free(bundle.buffer());
  ObjectMemory::tear_down();
  OS::tear_down();
  FlashRegistry::tear_down();
  return 0;
}
