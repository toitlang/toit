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

#pragma once

#include "../top.h"

#ifdef TOIT_RP2350

namespace toit {

class EventSource;

// Creates the process-wide I2C controller event source. The platform VM owns
// the returned object and must add it before any I2C primitive is used.
EventSource* create_rp2350_i2c_event_source();

}  // namespace toit

#endif  // TOIT_RP2350
