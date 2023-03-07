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

#include "virtual_call.h"

#include "../queryable_class.h"
#include "../set.h"

#include "../../bytecodes.h"

namespace toit {
namespace compiler {

using namespace ir;

bool is_This(Node* node, Class* holder, Method* method) {
  if (holder != method->holder()) return false;
  if (holder == null) return false;
  if (!(method->is_instance() || method->is_constructor())) return false;
  if (!node->is_ReferenceLocal()) return false;
  auto target = node->as_ReferenceLocal()->target();
  if (target->name() != Symbols::this_) return false;
  if (target->is_CapturedLocal()) {
    target = target->as_CapturedLocal()->local();
  }
  if (!target->is_Parameter()) return false;
  return target->as_Parameter()->index() == 0;
}

Type compute_guaranteed_type(Expression* node, Class* holder, Method* method) {
  if (node->is_ReferenceLocal()) {
    auto target = node->as_ReferenceLocal()->target();
    if (!target->is_effectively_final()) return Type::invalid();
    if (!target->type().is_class()) return Type::invalid();
    return target->type();
  } else if (node->is_CallStatic()) {
    auto method = node->as_CallStatic()->target()->target();
    if (!method->return_type().is_class()) return Type::invalid();
    return method->return_type();
  } else if (node->is_FieldLoad()) {
    auto load = node->as_FieldLoad();
    auto field = load->field();
    if (!field->type().is_class()) return Type::invalid();
    if (method->is_constructor() && is_This(load->receiver(), holder, method)) {
      // We can't yet take advantage of field-loads in constructors. In the static
      //   part of constructors we don't enforce the typing of fields.
      // We need more information to know whether we are in the dynamic part.
      return Type::invalid();
    }
    return field->type();
  } else if (node->is_Typecheck()) {
    auto check = node->as_Typecheck();
    if (check->is_as_check()) return check->type();
  }
  return Type::invalid();
}

} // namespace toit::compiler
} // namespace toit
