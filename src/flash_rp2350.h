// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once

#include "top.h"
#ifdef TOIT_RP2350
namespace toit {
namespace rp2350 {

struct Partition {
  uint32 offset;
  uint32 size;
  uint32 flags;
};

// The initial layout uses partition IDs 0/1 for firmware and 2 for storage.
// Fail closed if a different layout or permission set is installed.
bool partition(int index, Partition* result);
bool firmware_pair(Partition* a, Partition* b);
const uint8* flash_address(uint32 offset);
bool flash_erase(uint32 offset, uint32 size);
bool flash_write(uint32 offset, const uint8* bytes, uint32 size);

}  // namespace rp2350
}  // namespace toit
#endif
