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

#include "primitive.h"
#include "process.h"
#include "process_group.h"
#include "objects_inline.h"

#include <math.h>

namespace toit {

MODULE_IMPLEMENTATION(math, MODULE_MATH)

#define MATH_1_ARG(op) \
PRIMITIVE(op) { \
  ARGS(to_double, x); \
  return Primitive::allocate_double(op(x), process); \
}

#define MATH_2_ARG(op) \
PRIMITIVE(op) { \
  ARGS(to_double, x, to_double, y); \
  return Primitive::allocate_double(op(x, y), process); \
}

MATH_1_ARG(sin);
MATH_1_ARG(cos);
MATH_1_ARG(tan);
MATH_1_ARG(sinh);
MATH_1_ARG(cosh);
MATH_1_ARG(tanh);
MATH_1_ARG(asin);
MATH_1_ARG(acos);
MATH_1_ARG(atan);
MATH_2_ARG(atan2);
MATH_1_ARG(sqrt);
MATH_2_ARG(pow);
MATH_1_ARG(exp);
MATH_1_ARG(log);

} // namespace toit
