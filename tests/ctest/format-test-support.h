// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#pragma once

#include <stdio.h>
#include <stdlib.h>

// The compiler's ASSERT is intentionally compiled out in release builds.
// Formatter tests must retain their checks in every build configuration.
#undef ASSERT
#define ASSERT(condition) do {                                                \
  if (!(condition)) {                                                         \
    fprintf(stderr, "%s:%d: formatter test assertion failed: %s\n",          \
            __FILE__, __LINE__, #condition);                                  \
    exit(1);                                                                  \
  }                                                                           \
} while (false)
