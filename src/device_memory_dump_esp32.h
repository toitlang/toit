// Copyright (C) 2026 Toitware ApS.
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

#include "top.h"

#ifdef TOIT_ESP32

#include <esp_err.h>

namespace toit {

bool device_memory_dump_is_supported();
esp_err_t prepare_device_memory_dump(uint32 baud_rate);
[[noreturn]] void dump_device_memory(uint32 baud_rate);

}  // namespace toit

#endif  // TOIT_ESP32
