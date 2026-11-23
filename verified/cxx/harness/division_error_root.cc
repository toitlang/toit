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

// Check the Program accessor used by the integer division VeriFast sidecar.
// Symbolic root slots distinguish this root from every other slot.
#define private public
#define protected public
#include "prelude.h"
#include "program.h"
#undef private
#undef protected

using namespace toit;

extern Program division_program;

int main() {
  static_assert(Program::DIVISION_BY_ZERO_INDEX == 11, "division error root index");
  CXXV_ASSERT(division_program.division_by_zero() == division_program.roots_[11],
              "division accessor returns the modeled root");
}
