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

import .boot show run

/**
The system without the BLE service, for a firmware whose deployment installs
  a BLE provider container of its own (the built-in provider and a second
  one do not fit the ESP32 firmware partition together). Select it with
  CONFIG_TOIT_SYSTEM_SOURCE.
*/

main:
  run --no-ble
