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

#include "top.h"

namespace toit {

class Object;
class Process;

// Platform implementation shared by the common watchdog primitive and the
// compatibility APIs in the platform libraries.
Object* platform_watchdog_start(Process* process, int timeout_ms);
Object* platform_watchdog_feed(Process* process);
Object* platform_watchdog_stop(Process* process);

}  // namespace toit
