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

#include "../top.h"

#include <unordered_map>

namespace toit {
namespace compiler {

// Maps runtime method IDs to the full selector offsets used during compilation.
// The compiler-side type propagator uses this copy for newly emitted programs;
// runtime method headers also retain the offsets needed by runtime propagation.
using MethodSelectorOffsets = std::unordered_map<int, word>;

} // namespace toit::compiler
} // namespace toit
