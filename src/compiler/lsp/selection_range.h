// Copyright (C) 2026 Toitware ApS.
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

#include "../ast.h"
#include "../sources.h"
#include "protocol.h"

namespace toit {
namespace compiler {

/// Emits LSP selectionRange responses for the given cursor positions.
///
/// For each position, walks the AST and collects all node ranges that contain
/// the position, producing a sequence of ranges from innermost to outermost.
///
/// Both `full_range()` and `selection_range()` of each node are considered,
/// giving fine-grained expansion steps (e.g. method name → full method).
void emit_selection_ranges(ast::Unit* unit,
                           const std::vector<std::pair<int, int>>& positions,
                           SourceManager* source_manager,
                           LspProtocol* protocol);

} // namespace compiler
} // namespace toit
