// Copyright (C) 2020 Toitware ApS.
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

#include "dead_code.h"

namespace toit {
namespace compiler {

using namespace ir;

// Conservatively return true, if the expression could contain a variable declaration.
static bool can_contain_variable_declaration(Expression* expression) {
  return !(expression->is_Literal() ||
           expression->is_Reference() ||
           expression->is_LoopBranch() ||
           expression->is_FieldLoad() ||
           expression->is_Nop());
}

Node* simplify_sequence(Sequence* node) {
  List<Expression*> expressions = node->expressions();
  if (expressions.length() == 0) {
    // Not sure this can happen, but can't hurt.
    return _new LiteralNull(node->range());
  } else if (expressions.length() > 1) {
    return node;
  }
  // We can only drop the sequence if it isn't used as the lifetime delimiter of a variable.
  // For simplicity we just have a list of cases where we know that it will work.
  auto expression = expressions.first();
  if (expression->is_Sequence()) return expression;
  if (!can_contain_variable_declaration(expression)) return expression;
  // Look into returns.
  if (expression->is_Return() &&
      !can_contain_variable_declaration(expression->as_Return()->value())) {
    return expression;
  }
  return node;
}

} // namespace toit::compiler
} // namespace toit
