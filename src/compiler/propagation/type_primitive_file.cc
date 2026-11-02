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

TYPE_PRIMITIVE_SMI(open)

TYPE_PRIMITIVE(read) {
  result.add_byte_array(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE_SMI(write)
TYPE_PRIMITIVE_NULL(close)
TYPE_PRIMITIVE_NULL(unlink)
TYPE_PRIMITIVE_NULL(rmdir)
TYPE_PRIMITIVE_NULL(rename)
TYPE_PRIMITIVE_NULL(chdir)
TYPE_PRIMITIVE_NULL(chmod)
TYPE_PRIMITIVE_NULL(link)
TYPE_PRIMITIVE_STRING(readlink)
TYPE_PRIMITIVE_NULL(mkdir)

TYPE_PRIMITIVE(opendir) {
  failure.add_string(program);
}

TYPE_PRIMITIVE_BYTE_ARRAY(opendir2)

TYPE_PRIMITIVE(readdir) {
  result.add_byte_array(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE_NULL(closedir)

TYPE_PRIMITIVE(stat) {
  result.add_array(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE_BYTE_ARRAY(mkdtemp)
TYPE_PRIMITIVE_BOOL(is_open_file)

TYPE_PRIMITIVE(realpath) {
  result.add_string(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE_STRING(cwd)
TYPE_PRIMITIVE_BYTE_ARRAY(read_file_content_posix)
TYPE_PRIMITIVE_NULL(update_times)

}  // namespace toit::compiler
}  // namespace toit
