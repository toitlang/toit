// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only. See LICENSE in the top level directory.

#include "type_primitive.h"

namespace toit {
namespace compiler {

MODULE_TYPES(one_wire, MODULE_ONE_WIRE)

TYPE_PRIMITIVE_SMI(capabilities)
TYPE_PRIMITIVE_BYTE_ARRAY(init)
TYPE_PRIMITIVE_BYTE_ARRAY(create)
TYPE_PRIMITIVE_NULL(close)
TYPE_PRIMITIVE_NULL(start)
TYPE_PRIMITIVE_SMI(finish)
TYPE_PRIMITIVE_NULL(abort)

}  // namespace compiler
}  // namespace toit
