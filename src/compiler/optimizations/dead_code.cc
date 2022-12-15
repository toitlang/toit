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

static bool expression_terminates(Expression* expression,
                                  TypeDatabase* propagated_types) {
  if (expression->is_Return()) {
    return true;
  }
  if (expression->is_If()) {
    return expression_terminates(expression->as_If()->no(), propagated_types) &&
        expression_terminates(expression->as_If()->yes(), propagated_types);
  }
  if (expression->is_Sequence()) {
    // We know that all subexpressions are already optimized. As such, we only need to check
    //   the last expression in the list of subexpressions.
    List<Expression*> subexpressions = expression->as_Sequence()->expressions();
    return !subexpressions.is_empty() &&
        expression_terminates(subexpressions.last(), propagated_types);
  }
  if (propagated_types != null && expression->is_Call()) {
    if (expression->is_CallBuiltin()) return false;
    return propagated_types->does_not_return(expression->as_Call());
  }
  if (expression->is_CallStatic()) {
    auto target_method = expression->as_CallStatic()->target()->target();
    return target_method->does_not_return();
  }
  return false;
}

static bool is_dead_code(Expression* expression) {
  return expression->is_Literal() ||
      // A reference to a global could have side effects and we don't
      // know if it requires lazy initialization yet.
      expression->is_ReferenceBlock() ||
      expression->is_ReferenceClass() ||
      expression->is_ReferenceLocal() ||
      expression->is_ReferenceMethod() ||
      expression->is_FieldLoad() ||
      expression->is_Nop();
}

static int live_prefix(List<Expression*> expressions, TypeDatabase* propagated_types) {
  int prefix = 0;
  for (int i = 0; i < expressions.length(); i++) {
    Expression* expression = expressions[i];
    if (expression->is_If()) {
      prefix = i + 1;
    } else if (expression->is_Call()) {
      if (propagated_types->is_dead(expression->as_Call())) {
        fprintf(stderr, "[found dead prefix = %d (%d)]\n", prefix, expressions.length() - prefix);
        return prefix;
      }
    }
  }
  return expressions.length();
}

ir::Sequence* eliminate_dead_code(Sequence* node, TypeDatabase* propagated_types) {
  List<Expression*> expressions = node->expressions();
  int target_index = 0;
  for (int i = 0; i < expressions.length(); i++) {
    if (i != expressions.length() - 1 &&  // The last expression is the value of the sequence.
        is_dead_code(expressions[i])) continue;
    expressions[target_index++] = expressions[i];
  }

  if (target_index != expressions.length()) {
    expressions = expressions.sublist(0, target_index);
  }

/*
  if (propagated_types) {
    int prefix = live_prefix(expressions, propagated_types);
    if (prefix != expressions.length()) {
      expressions = expressions.sublist(0, prefix);
    }
  }
*/

  for (int i = 0; i < expressions.length() - 1; i++) {
    if (expression_terminates(expressions[i], propagated_types)) {
      expressions = expressions.sublist(0, i + 1);
      break;
    }
  }

  if (expressions.data() == node->expressions().data()) return node;
  return _new Sequence(expressions, node->range());
}

} // namespace toit::compiler
} // namespace toit
