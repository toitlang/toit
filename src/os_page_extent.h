// Copyright (C) 2026 Toit contributors.
#pragma once

#include "top.h"

namespace toit {

struct OSPageExtent {
  uword start;
  uword size;

  // The system page size is a positive power of two. Endpoints are inclusive
  // here so a range may extend through the last representable address.
  static bool covering(uword address, uword bytes, uword page_size, OSPageExtent* out) {
    *out = {address, 0};
    if (bytes == 0) return true;
    if (bytes - 1 > UINTPTR_MAX - address) return false;
    uword first = address & ~(page_size - 1);
    uword last = (address + (bytes - 1)) & ~(page_size - 1);
    if (last - first > UINTPTR_MAX - page_size) return false;
    *out = {first, (last - first) + page_size};
    return true;
  }

  static bool contained(uword address, uword bytes, uword page_size, OSPageExtent* out) {
    *out = {address, 0};
    if (bytes == 0) return true;
    if (bytes - 1 > UINTPTR_MAX - address) return false;
    uword skip = (0 - address) & (page_size - 1);
    if (skip >= bytes) return true;
    *out = {address + skip, (bytes - skip) & ~(page_size - 1)};
    return true;
  }
};

}  // namespace toit
