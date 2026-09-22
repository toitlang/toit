// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#include "type_primitive.h"

namespace toit {
namespace compiler {

MODULE_TYPES(ble_hci, MODULE_BLE_HCI)

TYPE_PRIMITIVE_ANY(init)
TYPE_PRIMITIVE_ANY(open)
TYPE_PRIMITIVE_ANY(open_management)
TYPE_PRIMITIVE_ANY(receive)
TYPE_PRIMITIVE_BOOL(send)
TYPE_PRIMITIVE_NULL(close)
TYPE_PRIMITIVE_ANY(diagnostics)
TYPE_PRIMITIVE_ANY(test)

} // namespace toit::compiler
} // namespace toit
