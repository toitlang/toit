// Copyright (C) 2026 Toit contributors.
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

MODULE_TYPES(usb_host, MODULE_USB_HOST)

TYPE_PRIMITIVE_BYTE_ARRAY(init)

TYPE_PRIMITIVE(create) {
  result.add_byte_array(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE_NULL(stop)
TYPE_PRIMITIVE_NULL(close)

TYPE_PRIMITIVE(device_open) {
  result.add_array(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE(device_close) {
  result.add_bool(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE_NULL(claim_interface)
TYPE_PRIMITIVE_BOOL(release_interface)

TYPE_PRIMITIVE(control_submit) {
  result.add_bool(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE(control_finish) {
  result.add_byte_array(program);
  result.add_smi(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE_SMI(out_submit)

TYPE_PRIMITIVE(out_finish) {
  result.add_smi(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE_NULL(in_submit)

TYPE_PRIMITIVE(in_finish) {
  result.add_byte_array(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE_NULL(cancel)
TYPE_PRIMITIVE_NULL(in_stream_start)

TYPE_PRIMITIVE(in_stream_read) {
  result.add_byte_array(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE(in_stream_stop) {
  result.add_bool(program);
  result.add_null(program);
  failure.add_string(program);
}

}  // namespace toit::compiler
}  // namespace toit
