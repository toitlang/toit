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
#include "../list.h"
#include "../map.h"
#include "../set.h"

namespace toit {
namespace compiler {

bool is_This(ir::Node* node, ir::Class* holder, ir::Method* method);

ir::Type compute_guaranteed_type(ir::Expression* node,
                                 ir::Class* holder,
                                 ir::Method* method,
                                 List<ir::Type> literal_types);

} // namespace toit::compiler
} // namespace toit

