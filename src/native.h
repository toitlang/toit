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

#include "interpreter.h"
#include "native_abi.h"
#include "objects.h"
#include "objects_inline.h"
#include "process.h"
#include "program.h"

// Support for programs that have been compiled to C++. See native_abi.h.
//
// A process runs either bytecodes or native code; never both.

namespace toit {

// Native programs don't have bytecodes. Each method is replaced by a record of
// the same size: the method header followed by the original id of the method,
// which stack traces use to find names and positions. The targets of
// non-local branches get records too, with -1 as their original id. Ids and
// entries keep pointing into these records, so the index of the record is all
// it takes to find the code.
inline word native_record_size() { return Method::entry_offset() + sizeof(int32); }

inline word native_record_index(word entry_bci) {
  return (entry_bci - Method::entry_offset()) / native_record_size();
}

// Whether the executable has native code for the program.
bool is_native_program(Program* program);

}  // namespace toit
