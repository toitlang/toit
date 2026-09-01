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

#ifndef TOIT_SRC_WATCHDOG_EC618_H_
#define TOIT_SRC_WATCHDOG_EC618_H_

namespace toit {

bool ec618_watchdog_init(int seconds);
void ec618_watchdog_feed();
void ec618_watchdog_deinit();

extern "C" void toit_watchdog_presleep();

}  // namespace toit

#endif  // TOIT_SRC_WATCHDOG_EC618_H_
