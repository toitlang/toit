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

#pragma once

#include "../ir.h"
#include "../map.h"
#include "../set.h"

namespace toit {
namespace compiler {

class QueryableClass;

/// Transforms virtual calls into static calls (when possible).
/// Transforms virtual getters/setters into field accesses (when possible).
ir::Expression* optimize_virtual_call(ir::CallVirtual* call,
                                      ir::Class* holder,
                                      ir::Method* method,
                                      UnorderedSet<Symbol>& field_names,
                                      UnorderedMap<ir::Class*, QueryableClass>& queryables);

} // namespace toit::compiler
} // namespace toit
