// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#pragma once

#include "../top.h"

namespace toit {

struct TerminalDimensions {
  int columns;
  int rows;
  int pixel_width;
  int pixel_height;

  bool operator==(const TerminalDimensions& other) const {
    return columns == other.columns &&
        rows == other.rows &&
        pixel_width == other.pixel_width &&
        pixel_height == other.pixel_height;
  }
};

// Returns zero on success and an OS error code otherwise.
int read_terminal_dimensions(int fd, TerminalDimensions* dimensions);

}  // namespace toit
