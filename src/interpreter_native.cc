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

#include "interpreter.h"
#include "native.h"
#include "objects_inline.h"
#include "process.h"
#include "snapshot.h"

namespace toit {

// Executables with native code run the native programs natively. The
// bytecodes of other programs run in the bytecode loop, if the executable
// has it. Each process runs one program, so the two never share a stack.
// This is their side of the interface that the engines implement.
Interpreter::Result Interpreter::run() {
  process_->object_heap()->leave_primitive();
  Result result(Result::PREEMPTED);
  if (NativeRuntime::run(this, &result)) return result;
  return run_bytecodes();
}

bool Interpreter::can_run(Program* program) {
  return has_bytecodes() || is_native_program(program);
}

// Native code starts at the function for the method. Bytecodes start where
// the code of the method starts.
Object* Interpreter::start_address(uint8* bcp) {
  return NativeRuntime::start_address(process_->program(), bcp);
}

// Replaces the default for bytecodes in objects.cc.
int Interpreter::return_bci(Program* program, uint8* return_address) {
  return NativeRuntime::return_bci(program, return_address);
}

#ifndef TOIT_FREERTOS
// The programs in the executable have their images compiled in. Other
// programs can only run as bytecodes.
ProgramImage Interpreter::spawn_image(const uint8* id, const uint8* snapshot, word length) {
  ProgramImage image = NativeRuntime::load_image_with_id(id);
  if (image.is_valid() || !has_bytecodes()) return image;
  return Snapshot(snapshot, length).read_image(id);
}
#endif

}  // namespace toit
