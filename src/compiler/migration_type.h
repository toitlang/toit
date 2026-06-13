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

#include "list.h"
#include "scanner.h"

namespace toit {
namespace compiler {

class Diagnostics;
class SymbolCanonicalizer;

namespace ast {
class Unit;
}

/// Attaches `// __TYPE-MIGRATION__ <name>: <type>` comments to the parameters of the
/// method declarations they precede.
///
/// Such a comment declares that a parameter of type `any` actually only
/// accepts a restricted set of types. Each comment contributes one type
/// alternative. If the type is followed by `Deprecated` (optionally with a
/// message), call sites that pass an argument of that type get a
/// deprecation warning.
///
/// Example:
///     // __TYPE-MIGRATION__ rx: gpio.Pin. Deprecated. Provide an integer instead.
///     // __TYPE-MIGRATION__ rx: int
///     create-uart --rx/any:
///
/// Temporary mechanism to migrate `any` parameters to concrete types.
void attach_migration_types(ast::Unit* unit,
                            List<Scanner::Comment> comments,
                            Source* source,
                            SymbolCanonicalizer* symbols,
                            Diagnostics* diagnostics);

} // namespace toit::compiler
} // namespace toit
