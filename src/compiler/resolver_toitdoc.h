// Copyright (C) 2018 Toitware ApS.
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

#include "toitdoc.h"

namespace toit {
namespace compiler {

class Diagnostics;
class Scope;
class Lsp;

class ToitdocScopeIterator {
 public:
  virtual void for_each(const std::function<void (Symbol)>& parameter_callback,
                        const std::function<void (Symbol, const ResolutionEntry&)>& callback) = 0;

};

Toitdoc<ir::Node*> resolve_toitdoc(Toitdoc<ast::Node*> ast_toitdoc,
                                   ast::Node* holder,
                                   Scope* scope,
                                   Lsp* lsp,
                                   const UnorderedMap<ir::Node*, ast::Node*>& ir_to_ast_map,
                                   Diagnostics* diagnostics);

} // namespace toit::compiler
} // namespace toit
