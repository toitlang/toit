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
#include "primitive.h"

namespace toit {

// Executables with native code can leave out the bytecode loop and the
// primitive tables, which only the bytecode loop uses. Then they can only
// run their native programs. Spawning other programs fails, because they
// can't run them (see Interpreter::can_run), so this is never called.

void Primitive::set_up() {}

bool Interpreter::has_bytecodes() {
  return false;
}

Interpreter::Result Interpreter::run_bytecodes() {
  FATAL("This executable can only run native programs");
}

}  // namespace toit
