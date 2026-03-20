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

#include "top.h"

#include "objects_inline.h"
#include "primitive.h"
#include "process.h"

namespace toit {

MODULE_IMPLEMENTATION(cellular, MODULE_CELLULAR)

PRIMITIVE(init)              { FAIL(UNIMPLEMENTED); }
PRIMITIVE(close)             { FAIL(UNIMPLEMENTED); }
PRIMITIVE(connect)           { FAIL(UNIMPLEMENTED); }
PRIMITIVE(disconnect)        { FAIL(UNIMPLEMENTED); }
PRIMITIVE(disconnect_reason) { FAIL(UNIMPLEMENTED); }
PRIMITIVE(get_ip)            { FAIL(UNIMPLEMENTED); }
PRIMITIVE(get_cell_info)     { FAIL(UNIMPLEMENTED); }

}  // namespace toit
