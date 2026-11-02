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

TYPE_PRIMITIVE_FLOAT(sin)
TYPE_PRIMITIVE_FLOAT(cos)
TYPE_PRIMITIVE_FLOAT(tan)
TYPE_PRIMITIVE_FLOAT(sinh)
TYPE_PRIMITIVE_FLOAT(cosh)
TYPE_PRIMITIVE_FLOAT(tanh)
TYPE_PRIMITIVE_FLOAT(asin)
TYPE_PRIMITIVE_FLOAT(acos)
TYPE_PRIMITIVE_FLOAT(atan)
TYPE_PRIMITIVE_FLOAT(atan2)
TYPE_PRIMITIVE_FLOAT(sqrt)
TYPE_PRIMITIVE_FLOAT(pow)
TYPE_PRIMITIVE_FLOAT(exp)
TYPE_PRIMITIVE_FLOAT(log)

}  // namespace toit::compiler
}  // namespace toit
