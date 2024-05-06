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

#include "ir.h"
#include "map.h"
#include "selector.h"

namespace toit {
namespace compiler {

class QueryableClass {
 public:
  typedef UnorderedMap<Selector<PlainShape>, ir::Method*> SelectorMap;

  QueryableClass() : class_(null) {}

  QueryableClass(ir::Class* klass, SelectorMap& methods)
      : class_(klass), methods_(methods) {}

  ir::Method* lookup(Selector<PlainShape> selector) const { return methods_.lookup(selector); }
  ir::Method* lookup(Selector<CallShape> selector) const {
    return methods_.lookup(Selector<PlainShape>(selector.name(), selector.shape().to_plain_shape()));
  }

  // Returns true, if the selector was in the class.
  bool remove(Selector<PlainShape> selector) { return methods_.remove(selector); }

  ir::Class* klass() const { return class_; }

  SelectorMap& methods() { return methods_; }

 private:
  ir::Class* class_;
  SelectorMap methods_;
};

/// Builds the queryable-map from plain shapes.
/// This is only valid *after* stubs have been inserted into the program.
UnorderedMap<ir::Class*, QueryableClass> build_queryables_from_plain_shapes(List<ir::Class*> classes, bool include_abstracts);

/// Builds the queryable-map from resolution shapes.
/// This is only valid *before* stubs have been inserted into the program.
/// This function needs to run through the whole program to find all valid selectors.
UnorderedMap<ir::Class*, QueryableClass> build_queryables_from_resolution_shapes(ir::Program* program, bool include_abstracts);

} // namespace toit::compiler
} // namespace toit
