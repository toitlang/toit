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

MODULE_TYPES(file, MODULE_FILE)

TYPE_PRIMITIVE_ANY(open)
TYPE_PRIMITIVE_ANY(read)
TYPE_PRIMITIVE_ANY(write)
TYPE_PRIMITIVE_ANY(close)
TYPE_PRIMITIVE_ANY(unlink)
TYPE_PRIMITIVE_ANY(rmdir)
TYPE_PRIMITIVE_ANY(rename)
TYPE_PRIMITIVE_ANY(chdir)
TYPE_PRIMITIVE_ANY(mkdir)
TYPE_PRIMITIVE_ANY(opendir)
TYPE_PRIMITIVE_ANY(opendir2)
TYPE_PRIMITIVE_ANY(readdir)
TYPE_PRIMITIVE_ANY(closedir)
TYPE_PRIMITIVE_ANY(stat)
TYPE_PRIMITIVE_ANY(mkdtemp)
TYPE_PRIMITIVE_ANY(is_open_file)
TYPE_PRIMITIVE_ANY(realpath)
TYPE_PRIMITIVE_ANY(cwd)

}  // namespace toit::compiler
}  // namespace toit
