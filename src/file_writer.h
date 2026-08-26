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

#include <stddef.h>

#include "top.h"

namespace toit {

// Writes a complete file through a temporary file in the destination
// directory, then atomically replaces the destination. Existing permission
// bits are preserved. As with any rename-based replacement, inode identity,
// hard-link relationships, and other platform-specific metadata are not
// preserved. `create_mode` is used only for a new file and is filtered by the
// process umask.
//
// Returns false without modifying the destination on any failure before the
// final rename.
bool write_file_atomically(const char* path,
                           const uint8* content,
                           size_t size,
                           int create_mode = 0666);

} // namespace toit
