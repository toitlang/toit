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

#include "typecheck.h"
#include "utils.h"

namespace toit {
namespace compiler {

using namespace ir;

Expression* optimize_typecheck(Typecheck* node, Class* holder, Method* method) {
  // Currently we don't know anything about incoming parameter types.
  if (node->kind() == Typecheck::PARAMETER_AS_CHECK) return node;
  auto expression = node->expression();
  ASSERT(!node->type().is_none());
  auto expression_type = compute_guaranteed_type(expression, holder, method);
  if (!expression_type.is_valid()) return node;

  auto checked_type = node->type();
  Class* expression_class = null;
  Class* checked_class = null;

  if (checked_type.is_any()) goto success;
  if (expression_type.is_nullable() && !checked_type.is_nullable()) return node;

  expression_class = expression_type.klass();
  checked_class = checked_type.klass();

  if (expression_class->is_interface() && !checked_class->is_interface()) {
    // For now just give up.
    // We can do better, by looking at all the classes that implement the interface.
    return node;
  }
  if (checked_class->is_interface()) {
    std::vector<ir::Class*> queued;
    UnorderedSet<ir::Class*> handled;

    queued.push_back(expression_class);
    while (!queued.empty()) {
      // Note that `current` can be an interface class or not.
      auto current = queued.back();
      queued.pop_back();
      // Avoid infinite loops with interfaces.
      if (handled.contains(current)) {
        continue;
      }
      handled.insert(current);
      if (current == checked_class) goto success;
      if (current->super() != null) queued.push_back(current->super());
      for (auto inter : current->interfaces()) {
        queued.push_back(inter);
      }
    }
    // Without more work we can't know whether the check would actually succeed, so
    // let the check happen at runtime.
    return node;
  }
  if (!checked_class->is_interface()) {
    ASSERT(!expression_class->is_interface());
    // Just need to check whether the checked_class is a superclass of the expression_class.
    auto current = expression_class;
    while (current != null) {
      if (current == checked_class) goto success;
      current = current->super();
    }
    // TODO(florian): we can easily check whether checked_class is a subclass of expression_class.
    //   If it is not, we know that the check will fail.
    return node;
  }
  UNREACHABLE();

  success:
  if (node->is_as_check()) {
    return expression;
  } else if (expression->is_ReferenceLocal() || expression->is_Literal()) {
    return _new LiteralBoolean(true, node->range());
  } else {
    return _new Sequence(ListBuilder<Expression*>::build(expression, _new LiteralBoolean(true, node->range())),
                         node->range());
  }
}

} // namespace toit::compiler
} // namespace toit
