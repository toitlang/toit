// Copyright (C) 2022 Toitware ApS.
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

#include "selection.h"
#include "../package.h"

namespace toit {
namespace compiler {

// Unwraps an ir::Reference* node to its underlying definition.
//
// The resolver callbacks provide resolved nodes that may be wrapped in
// ir::Reference nodes (ReferenceLocal, ReferenceGlobal, ReferenceMethod,
// ReferenceClass). This function strips the wrapper to get the actual
// definition node (Local, Global, Method, Class), which is needed for
// pointer identity comparisons when searching for references.
ir::Node* unwrap_reference(ir::Node* node) {
  if (node == null) return null;
  if (node->is_Reference()) return node->as_Reference()->target();
  return node;
}

// Returns the name of the given target node as a C string.
//
// Supports Method, Class, Field, and Local nodes. Returns null for
// unsupported node types.
const char* target_name(ir::Node* target) {
  if (target == null) return null;
  if (target->is_Method()) return target->as_Method()->name().c_str();
  if (target->is_Class()) return target->as_Class()->name().c_str();
  if (target->is_Field()) return target->as_Field()->name().c_str();
  if (target->is_Local()) return target->as_Local()->name().c_str();
  return null;
}

// Returns the name range of the given target node.
//
// Supports Method, Class, Field, and Local nodes. Returns an invalid
// range for unsupported node types.
Source::Range target_range(ir::Node* target) {
  if (target == null) return Source::Range::invalid();
  if (target->is_Method()) return target->as_Method()->range();
  if (target->is_Class()) return target->as_Class()->range();
  if (target->is_Field()) return target->as_Field()->range();
  if (target->is_Local()) return target->as_Local()->range();
  return Source::Range::invalid();
}

// Returns whether the given target node is defined in the SDK.
//
// SDK symbols cannot be renamed because their source files are not
// user-editable.
bool is_sdk_target(ir::Node* target, SourceManager* source_manager) {
  Source::Range range = target_range(target);
  if (!range.is_valid()) return false;
  auto* source = source_manager->source_for_position(range.from());
  if (source == null) return false;
  return source->package_id() == Package::SDK_PACKAGE_ID;
}

} // namespace toit::compiler
} // namespace toit
