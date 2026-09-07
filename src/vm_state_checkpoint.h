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

#pragma once

#include "top.h"

namespace toit {

enum VmStateCheckpoint : uint32 {
  VM_STATE_MUTATOR_ARMED = 1,
  VM_STATE_SCAVENGE_STARTED = 2,
  VM_STATE_SCAVENGE_AFTER_FORWARDING = 3,
  VM_STATE_SCAVENGE_AFTER_ROOTS = 4,
  VM_STATE_SCAVENGE_COMPLETE = 5,
  VM_STATE_MARK_AFTER_ROOTS = 6,
  VM_STATE_MARK_COMPLETE = 7,
  VM_STATE_SWEEP_STARTED = 8,
  VM_STATE_COMPACTION_STARTED = 9,
  VM_STATE_GC_COMPLETE = 10,
};

#ifdef TOIT_VM_STATE_CHECKPOINTS

void vm_state_checkpoint_arm();
void vm_state_checkpoint(VmStateCheckpoint checkpoint, const void* context);
bool vm_state_checkpoint_requested(VmStateCheckpoint checkpoint);

#else

inline void vm_state_checkpoint_arm() {}
inline void vm_state_checkpoint(VmStateCheckpoint, const void*) {}
inline bool vm_state_checkpoint_requested(VmStateCheckpoint) { return false; }

#endif

}  // namespace toit
