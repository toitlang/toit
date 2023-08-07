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

MODULE_TYPES(zlib, MODULE_ZLIB)

TYPE_PRIMITIVE_ANY(adler32_start)
TYPE_PRIMITIVE_ANY(adler32_add)
TYPE_PRIMITIVE_ANY(adler32_get)
TYPE_PRIMITIVE_ANY(adler32_clone)
TYPE_PRIMITIVE_ANY(rle_start)
TYPE_PRIMITIVE_ANY(rle_add)
TYPE_PRIMITIVE_ANY(rle_finish)
TYPE_PRIMITIVE_ANY(zlib_init_deflate)
TYPE_PRIMITIVE_ANY(zlib_init_inflate)
TYPE_PRIMITIVE_ANY(zlib_write)
TYPE_PRIMITIVE_ANY(zlib_read)
TYPE_PRIMITIVE_NULL(zlib_close)
TYPE_PRIMITIVE_NULL(zlib_uninit)

}  // namespace toit::compiler
}  // namespace toit
