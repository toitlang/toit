// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The loader refuses a program whose error roots are not pairwise distinct
// objects: the retry protocol of the C++ primitives (v2_primitive_failed)
// tells an out-of-memory failure from the others by its root, and the C++
// proofs of the retry rule rely on the check (Program::has_valid_error_roots,
// verified/cxx/annotated/loader/error_roots.render). Compiled with
// -fno-access-control to write the roots of a loaded image.

#include "../../src/top.h"
#include "../../src/compiler/compiler.h"
#include "../../src/flags.h"
#include "../../src/flash_registry.h"
#include "../../src/os.h"
#include "../../src/primitive_policy.h"
#include "../../src/process_group.h"
#include "../../src/program.h"
#include "../../src/scheduler.h"
#include "../../src/snapshot.h"
#include "../../src/vm.h"

#include <sys/mman.h>

namespace toit {

static bool group_created(VM* vm, Program* program) {
  ProcessGroup* group = ProcessGroup::create(vm->scheduler()->next_group_id(), program, null,
                                             PrimitivePolicy::trusted());
  if (group == null) return false;
  delete group;
  return true;
}

static void test(VM* vm, Program* program) {
  if (!program->has_valid_error_roots()) FATAL("compiled program has invalid error roots");
  if (!group_created(vm, program)) FATAL("compiled program refused");
  int checks = 0;
  for (int i = Program::FIRST_ERROR_INDEX; i < Program::ROOT_COUNT; i++) {
    for (int j = i + 1; j < Program::ROOT_COUNT; j++) {
      Object* saved = program->roots_[j];
      program->roots_[j] = program->roots_[i];
      if (program->has_valid_error_roots()) FATAL("error roots %d and %d equal but accepted", i, j);
      // The whole loader path refuses it; a sample of pairs (each refusal
      // prints a line), including every pair with an out-of-memory root.
      bool oom = i == Program::ALLOCATION_FAILED_INDEX || i == Program::MALLOC_FAILED_INDEX ||
                 i == Program::CROSS_PROCESS_GC_INDEX || j == Program::MALLOC_FAILED_INDEX ||
                 j == Program::CROSS_PROCESS_GC_INDEX;
      if ((oom || j == Program::ROOT_COUNT - 1) && group_created(vm, program)) {
        FATAL("error roots %d and %d equal but the group was created", i, j);
      }
      program->roots_[j] = saved;
      checks++;
    }
  }
  int errors = Program::ROOT_COUNT - Program::FIRST_ERROR_INDEX;
  if (checks != errors * (errors - 1) / 2) FATAL("not every pair checked");
  if (!program->has_valid_error_roots()) FATAL("restored roots refused");
  // Only the error roots must be distinct: another root may be one of them.
  Object* saved = program->roots_[Program::app_sdk_info_INDEX];
  program->roots_[Program::app_sdk_info_INDEX] = program->roots_[Program::ALLOCATION_FAILED_INDEX];
  if (!program->has_valid_error_roots()) FATAL("a non-error root counted as an error root");
  program->roots_[Program::app_sdk_info_INDEX] = saved;
  // Each error root must be a heap reference that a marked error does not
  // confuse with an immediate one (an address below MAX_TAGGED_ERROR).
  Object* not_heap[] = {
    Smi::from(42),
    reinterpret_cast<Object*>(Error::MAX_TAGGED_ERROR - 4 + Object::HEAP_TAG),
    reinterpret_cast<Object*>(reinterpret_cast<uword>(program->roots_[Program::OUT_OF_BOUNDS_INDEX]) + 2),
  };
  for (int i = Program::FIRST_ERROR_INDEX; i < Program::ROOT_COUNT; i++) {
    for (Object* bad : not_heap) {
      Object* saved = program->roots_[i];
      program->roots_[i] = bad;
      if (program->has_valid_error_roots()) FATAL("error root %d is not a heap reference but accepted", i);
      program->roots_[i] = saved;
    }
  }
  if (!group_created(vm, program)) FATAL("restored program refused");
  printf("%d pairs of error roots checked\n", checks);
}

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
  {
    VM vm;
    vm.load_platform_event_sources();
    auto image = bundle.snapshot().read_image(null);
    // The loaded image is read-only; the test rewrites its roots.
    if (mprotect(image.address(), image.byte_size(), PROT_READ | PROT_WRITE) != 0) FATAL("mprotect");
    test(&vm, image.program());
    image.release();
  }
  free(bundle.buffer());
  ObjectMemory::tear_down();
  OS::tear_down();
  FlashRegistry::tear_down();
  return 0;
}
