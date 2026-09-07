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

#include "vm_state_checkpoint.h"

#ifdef TOIT_VM_STATE_CHECKPOINTS

namespace toit {

extern "C" {

volatile uint32 toit_vm_state_checkpoint_requested = 0;
volatile uint32 toit_vm_state_checkpoint_current = 0;
volatile uword toit_vm_state_checkpoint_context = 0;
volatile uint32 toit_vm_state_checkpoints_armed = 0;

__attribute__((noinline, used)) void toit_vm_state_checkpoint_hit() {
  asm volatile("" ::: "memory");
}

__attribute__((noinline, used)) void toit_vm_state_checkpoint_arm_gate() {
  toit_vm_state_checkpoints_armed = 1;
  vm_state_checkpoint(VM_STATE_MUTATOR_ARMED, null);
}

}  // extern "C"

void vm_state_checkpoint_arm() {
  toit_vm_state_checkpoint_arm_gate();
}

void vm_state_checkpoint(VmStateCheckpoint checkpoint, const void* context) {
  if (!toit_vm_state_checkpoints_armed) return;
  if (toit_vm_state_checkpoint_requested != static_cast<uint32>(checkpoint)) return;
  toit_vm_state_checkpoint_current = checkpoint;
  toit_vm_state_checkpoint_context = reinterpret_cast<uword>(context);
  toit_vm_state_checkpoint_hit();
}

bool vm_state_checkpoint_requested(VmStateCheckpoint checkpoint) {
  return toit_vm_state_checkpoints_armed &&
      toit_vm_state_checkpoint_requested == static_cast<uint32>(checkpoint);
}

}  // namespace toit

#endif  // TOIT_VM_STATE_CHECKPOINTS
