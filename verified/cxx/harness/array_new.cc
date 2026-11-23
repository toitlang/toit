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

// Bridge the empty-array accessor used by array_new's proof to the VM root table.
#define private public
#define protected public
#include "prelude.h"
#include "program.h"
#include "objects_inline.h"
#undef private
#undef protected

using namespace toit;

extern Program array_program;

int main() {
  static_assert(Program::empty_array_INDEX == 3, "empty array root index");
  CXXV_ASSERT(array_program.empty_array() == array_program.roots_[3],
              "array_new returns the modeled empty-array root");
  CXXV_ASSERT(Array::ARRAYLET_SIZE <= Array::max_length_in_process(),
              "every permitted arraylet fits the process object-size limit");
}
