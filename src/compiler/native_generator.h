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

#include <vector>
#include <string>

namespace toit {

class Program;

namespace compiler {

class TypeDatabase;

// Generates C++ code for all the given methods. See native.h.
// The cold methods are always optimized for size.
std::string generate_native_code(Program* program, TypeDatabase* types, std::vector<int> methods,
                                 const std::vector<int>& cold_methods);

} // namespace toit::compiler
} // namespace toit
