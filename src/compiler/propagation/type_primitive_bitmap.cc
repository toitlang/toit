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

MODULE_TYPES(bitmap, MODULE_BITMAP)

TYPE_PRIMITIVE_ANY(draw_text)
TYPE_PRIMITIVE_ANY(byte_draw_text)
TYPE_PRIMITIVE_ANY(draw_bitmap)
TYPE_PRIMITIVE_ANY(draw_bytemap)
TYPE_PRIMITIVE_ANY(byte_zap)
TYPE_PRIMITIVE_ANY(blit)
TYPE_PRIMITIVE_ANY(rectangle)
TYPE_PRIMITIVE_ANY(byte_rectangle)
TYPE_PRIMITIVE_ANY(composit)
TYPE_PRIMITIVE_ANY(bytemap_blur)

}  // namespace toit::compiler
}  // namespace toit
