// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
// Linked only into an explicitly selected hardware fault-test image.
#include "storage-interruption-test.h"
#include <string.h>
#include <unistd.h>
#include "hardware/flash.h"
#include "hardware/sync.h"
#include "pico/stdlib.h"

namespace toit {
static unsigned mode = 0;
static bool published = false;

void rp2040_storage_test_arm(const void* bytes, unsigned size) {
  if (size != 16 || memcmp(bytes, "TOIT-RP2040-CUT", 15) != 0) return;
  mode = static_cast<const uint8_t*>(bytes)[15];
  published = false;
}

void rp2040_storage_test_before_program(uint32_t offset, uint8_t* page, bool header) {
  if (mode == 1 && !header) {
    // The replacement fixture contains a multi-page array of 0x22 bytes.
    for (unsigned i = 0; i < 128; i++) if (page[i] != 0x22) return;
    memset(page + 128, 0xff, 128);
  } else if (mode == 2 && header) {
    // Publish only the first half of the allocation header; preserve payload.
    memset(page + 24, 0xff, 24);
  } else if (mode == 6 && !header && page[0] == 0 && page[1] == 0 &&
             page[2] == 0 && page[3] == 0) {
    // Invalidate only half of the marker, leaving the payload untouched.
    memcpy(page + 2, reinterpret_cast<const void*>(XIP_BASE + offset + 2), 2);
  } else {
    return;
  }
  save_and_disable_interrupts();
  flash_range_program(offset, page, 256);
  _exit(99);  // The tested native failure path forces a full recovery reset.
}

void rp2040_storage_test_after_program(bool header) {
  if (!header) return;
  published = true;
  if (mode == 3) _exit(99);
}

void rp2040_storage_test_before_erase(uint32_t offset) {
  if ((mode != 4 || !published) && mode != 5) return;
  // Reproduce a partially erased sector on actual NOR: erase, then restore
  // the prefix. This is a deterministic fault model, not a power-supply cut.
  uint8_t sector[4096];
  memcpy(sector, reinterpret_cast<const void*>(XIP_BASE + offset), sizeof(sector));
  memset(sector + 128, 0xff, sizeof(sector) - 128);
  save_and_disable_interrupts();
  flash_range_erase(offset, sizeof(sector));
  flash_range_program(offset, sector, sizeof(sector));
  _exit(99);
}
}
