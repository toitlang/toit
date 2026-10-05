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

TYPE_PRIMITIVE_ANY(init)
TYPE_PRIMITIVE_ANY(create)
TYPE_PRIMITIVE_NULL(close)
TYPE_PRIMITIVE_ANY(device_open)
TYPE_PRIMITIVE_NULL(device_close)
TYPE_PRIMITIVE_NULL(claim_interface)
TYPE_PRIMITIVE_NULL(release_interface)
TYPE_PRIMITIVE_ANY(control_submit)
TYPE_PRIMITIVE_ANY(control_finish)
TYPE_PRIMITIVE_SMI(out_submit)
TYPE_PRIMITIVE_ANY(out_finish)
TYPE_PRIMITIVE_NULL(in_submit)
TYPE_PRIMITIVE_ANY(in_finish)
TYPE_PRIMITIVE_NULL(cancel)
TYPE_PRIMITIVE_NULL(in_stream_start)
TYPE_PRIMITIVE_ANY(in_stream_read)
TYPE_PRIMITIVE_NULL(in_stream_stop)

}  // namespace toit::compiler
}  // namespace toit
