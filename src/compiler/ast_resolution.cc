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

#include "ast_resolution.h"

#include "ast.h"
#include "resolution.h"

namespace toit {
namespace compiler {
namespace resolution {

thread_local ast::Node* Origin::current_ = null;

void AstNode::attach(ast::Node* syntax) {
  ASSERT(syntax != null);
  syntax_ = syntax;
  syntax->set_resolution(this);
}

void AstNode::accept(Visitor* visitor) { information_->dispatch(visitor); }
Type AstNode::accept(ReturningVisitor<Type>* visitor) { return information_->dispatch(visitor); }

} // namespace toit::compiler::resolution
} // namespace toit::compiler
} // namespace toit
