// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once
#include <stdint.h>
#include <stddef.h>

namespace toit {
namespace rp2350 {

struct ImageHash {
  static const unsigned MAX_RANGES = 16;
  struct Range { uint32_t offset; uint32_t size; } ranges[MAX_RANGES];
  unsigned range_count;
  uint32_t block_offset;
  uint32_t block_hash_size;
  uint32_t digest_offset;
};

// Accepts the SDK's two-block, SHA-256-sealed Arm Secure trial image format.
// Returns the exact hash input ranges; the caller must verify their digest.
// Deliberately rejects other PICOBIN layouts rather than guessing ROM policy.
// first_sector optionally overlays the still-unpublished header in SRAM.
bool parse_ota_image(const uint8_t* bytes, size_t size, ImageHash* result,
                     const uint8_t* first_sector = nullptr);

}  // namespace rp2350
}  // namespace toit
