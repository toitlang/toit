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

namespace toit {

// Native code doesn't use the primitive tables.
void Primitive::set_up() {}

// Executables that are compiled to native code don't have the bytecode
// loop from interpreter_run.cc, because all their programs are native code.
// This is their side of the interface that the engines implement.
Interpreter::Result Interpreter::run() {
  process_->object_heap()->leave_primitive();
  Result result(Result::PREEMPTED);
  if (!NativeRuntime::run(this, &result)) {
    FATAL("Native executables can only run native programs");
  }
  return result;
}

Object* Interpreter::start_address(uint8* bcp) {
  return NativeRuntime::start_address(process_->program(), bcp);
}

// Replaces the default for bytecodes in objects.cc.
int Interpreter::return_bci(Program* program, uint8* return_address) {
  return NativeRuntime::return_bci(program, return_address);
}

// The programs in the executable have their images compiled in. The image is
// invalid for any other program, because there is no code for it.
ProgramImage Interpreter::spawn_image(const uint8* id, const uint8* snapshot, word length) {
  return NativeRuntime::load_image_with_id(id);
}

}  // namespace toit
