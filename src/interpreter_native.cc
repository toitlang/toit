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
#include "objects_inline.h"
#include "process.h"

namespace toit {

// Executables that are compiled to native code don't have the bytecode
// loop from interpreter_run.cc, because all their programs are native code.
Interpreter::Result Interpreter::run() {
  process_->object_heap()->leave_primitive();
  Result result(Result::PREEMPTED);
  if (native_runner_ == null || !native_runner_(this, &result)) {
    FATAL("Native executables can only run native programs");
  }
  return result;
}

}  // namespace toit
