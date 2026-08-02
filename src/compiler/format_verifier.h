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

namespace toit {
namespace compiler {

namespace ast {
class Unit;
}

class Scanner;
class Source;
class SourceManager;

// Re-parses formatter output and verifies both AST equivalence and comment
// preservation. Diagnostics name `out_path`; the output buffer remains owned
// by the caller.
bool verify_formatted_output(SourceManager* source_manager,
                             Source* original_source,
                             Scanner* original_scanner,
                             ast::Unit* original_unit,
                             const uint8* formatted,
                             int formatted_size,
                             const char* out_path);

} // namespace toit::compiler
} // namespace toit

