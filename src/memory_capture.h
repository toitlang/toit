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

#ifdef TOIT_ESP32
#include <sdkconfig.h>
#if CONFIG_TOIT_MEMORY_CAPTURE
#define TOIT_MEMORY_CAPTURE
#endif
#elif !defined(TOIT_FREERTOS)
#define TOIT_MEMORY_CAPTURE
#endif

#ifdef TOIT_MEMORY_CAPTURE

namespace toit {

enum MemoryCaptureStart {
  MEMORY_CAPTURE_STARTED,
  MEMORY_CAPTURE_ALREADY_RUNNING,
  MEMORY_CAPTURE_OUT_OF_MEMORY,
};

// Starts a capture of the memory state of the system on a separate thread.
// The capture pauses all Toit processes and writes their heaps, their roots,
// and the allocations of the system heap to stdout. The format is described
// in memory_capture.cc.
MemoryCaptureStart start_memory_capture(const char* reason);

// Returns true when the most recently started capture has completed.
bool is_memory_capture_done();

}  // namespace toit

#endif  // TOIT_MEMORY_CAPTURE
