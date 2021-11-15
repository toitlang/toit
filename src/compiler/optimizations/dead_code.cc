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

#include "dead_code.h"

namespace toit {
namespace compiler {

using namespace ir;

static bool expression_terminates(Expression* expression, Program* program) {
  if (expression->is_Return()) return true;
  if (expression->is_If() &&
      expression_terminates(expression->as_If()->no(), program) &&
      expression_terminates(expression->as_If()->yes(), program)) {
    return true;
  }
  if (expression->is_Sequence()) {
    // We know that all subexpressions are already optimized. As such, we only need to check
    //   the last expression in the list of subexpressions.
    List<Expression*> subexpressions = expression->as_Sequence()->expressions();
    return !subexpressions.is_empty() && expression_terminates(subexpressions.last(), program);
  }
  if (expression->is_CallStatic()) {
    auto target_method = expression->as_CallStatic()->target()->target();
    return target_method->does_not_return();
  }
  return false;
}

static bool is_dead_code(Expression* expression) {
  return expression->is_Literal() ||
      // A reference to a global could have side effects.
      expression->is_ReferenceBlock() ||
      expression->is_ReferenceClass() ||
      expression->is_ReferenceLocal() ||
      expression->is_ReferenceMethod() ||
      expression->is_FieldLoad() ||
      expression->is_Nop();
}

ir::Sequence* eliminate_dead_code(Sequence* node, Program* program) {
  List<Expression*> expressions = node->expressions();
  int target_index = 0;
  for (int i = 0; i < expressions.length(); i++) {
    if (i != expressions.length() - 1 &&  // The last expression is the value of the sequence.
        is_dead_code(expressions[i])) continue;
    expressions[target_index++] = expressions[i];
  }
  if (target_index != expressions.length()) {
    expressions = expressions.sublist(0, target_index);
    node->replace_expressions(expressions);
  }

  for (int i = 0; i < expressions.length() - 1; i++) {
    if (expression_terminates(expressions[i], program)) {
      return _new Sequence(expressions.sublist(0, i + 1), node->range());
    }
  }
  return node;
}

} // namespace toit::compiler
} // namespace toit
