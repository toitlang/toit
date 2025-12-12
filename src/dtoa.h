// Copyright (C) 2025 Toit contributors.
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

namespace toit {

// Includes the terminating '\0'.
constexpr int MAX_BUFFER_SIZE_DOUBLE_TO_SHORTEST = 26;

void double_to_shortest(double value, char* buffer, size_t buffer_size);

} // namespace toit
