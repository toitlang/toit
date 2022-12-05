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

#include "type_primitive.h"

namespace toit {
namespace compiler {

MODULE_TYPES(math, MODULE_MATH)

TYPE_PRIMITIVE_ANY(sin)
TYPE_PRIMITIVE_ANY(cos)
TYPE_PRIMITIVE_ANY(tan)
TYPE_PRIMITIVE_ANY(sinh)
TYPE_PRIMITIVE_ANY(cosh)
TYPE_PRIMITIVE_ANY(tanh)
TYPE_PRIMITIVE_ANY(asin)
TYPE_PRIMITIVE_ANY(acos)
TYPE_PRIMITIVE_ANY(atan)
TYPE_PRIMITIVE_ANY(atan2)
TYPE_PRIMITIVE_ANY(sqrt)
TYPE_PRIMITIVE_ANY(pow)
TYPE_PRIMITIVE_ANY(exp)
TYPE_PRIMITIVE_ANY(log)

}  // namespace toit::compiler
}  // namespace toit
