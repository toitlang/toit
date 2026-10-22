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

#include "queryable_class.h"
#include "set.h"

namespace toit {
namespace compiler {

using namespace ir;

UnorderedMap<Class*, QueryableClass> build_queryables_from_plain_shapes(List<Class*> classes, bool include_abstracts) {
  UnorderedMap<Class*, QueryableClass> result;
  for (auto klass : classes) {
    QueryableClass::SelectorMap methods;

    if (klass->super() != null) {
      // We know we already dealt with the super, because the classes are sorted
      //   by inheritance.
      // Insert the superclass methods first, and then overwrite the ones that this class has.
      methods.add_all(result[klass->super()].methods());
    }
    for (auto method : klass->methods()) {
      if (!include_abstracts && method->is_abstract()) continue;
      Selector<PlainShape> selector(method->name(), method->plain_shape());
      methods[selector] = method;
    }

    result[klass] = QueryableClass(klass, methods);
  }
  return result;
}

} // namespace toit::compiler
} // namespace toit
