// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#if defined(TOIT_RP2350) || defined(TOIT_RP2350_OTA_TEST)
#include "ota_image_rp2350.h"
#include "boot/picobin.h"

namespace toit {
namespace rp2350 {
namespace {

struct ImageBytes {
  const uint8_t* flash;
  const uint8_t* first_sector;
};

uint32_t word_at(const ImageBytes& image, uint32_t offset) {
  const uint8_t* bytes = image.first_sector != nullptr && offset < 4096
      ? image.first_sector : image.flash;
  return uint32_t(bytes[offset]) | (uint32_t(bytes[offset + 1]) << 8) |
      (uint32_t(bytes[offset + 2]) << 16) | (uint32_t(bytes[offset + 3]) << 24);
}

struct Block {
  uint32_t end;
  uint32_t next;
  uint32_t version;
  bool hashed;
};

bool parse_block(const ImageBytes& bytes, uint32_t size, uint32_t start,
                 bool terminal, Block* block, ImageHash* hash) {
  if ((start & 3) || start > size || size - start < 20 ||
      word_at(bytes, start) != PICOBIN_BLOCK_MARKER_START) return false;
  // EXE, Arm, Secure, RP2350, TBYB. TBYB is excluded from the ROM hash and
  // must be checked separately in BOTH image definitions.
  if (word_at(bytes, start + 4) != 0x90210142) return false;
  uint32_t at = start + 8;
  bool version = false;
  bool load_map = false;
  bool hash_def = false;
  bool hash_value = false;
  while (at <= size - 12 && at - start < PICOBIN_MAX_IMAGE_DEF_BLOCK_SIZE - 12) {
    uint32_t header = word_at(bytes, at);
    uint32_t tag = header & 0xff;
    uint32_t words = (header >> 8) & ((tag & 0x80) ? 0xffff : 0xff);
    if (tag == PICOBIN_BLOCK_ITEM_2BS_LAST) {
      if (words != (at - start - 4) / 4 || (header >> 24) != 0 ||
          word_at(bytes, at + 8) != PICOBIN_BLOCK_MARKER_END) return false;
      int64_t next = int64_t(start) + int32_t(word_at(bytes, at + 4));
      if (next < 0 || next >= size || (next & 3)) return false;
      block->next = uint32_t(next);
      block->end = at + 12;
      block->hashed = load_map && hash_def && hash_value;
      return version && (terminal ? block->hashed : !load_map && !hash_def && !hash_value);
    }
    if (words == 0 || words > (size - at) / 4 ||
        at - start + 4 * words > PICOBIN_MAX_IMAGE_DEF_BLOCK_SIZE - 12) return false;
    if (tag == PICOBIN_BLOCK_ITEM_1BS_VERSION) {
      // No rollback/OTP version provisioned by this port.
      if (version || header != 0x248 || hash_def) return false;
      version = true;
      block->version = word_at(bytes, at + 4);
    } else if (tag == PICOBIN_BLOCK_ITEM_LOAD_MAP) {
      unsigned count = header >> 24;
      if (!terminal || load_map || hash_def || count == 0 ||
          count > ImageHash::MAX_RANGES || words != 1 + 3 * count) return false;
      load_map = true;
      hash->range_count = count;
      uint32_t covered = 0;
      for (unsigned i = 0; i < count; i++) {
        uint32_t entry = at + 4 + 12 * i;
        int64_t offset = int64_t(at) + int32_t(word_at(bytes, entry));
        uint32_t runtime = word_at(bytes, entry + 4);
        uint32_t length = word_at(bytes, entry + 8);
        if ((offset | runtime | length) & 3) return false;
        // SDK ELF segments may have zero-filled alignment gaps (not included
        // in the ROM hash). Accept only those gaps, in increasing order.
        if (word_at(bytes, entry) == 0 || offset < covered || offset > start || length == 0 ||
            length > start - offset) return false;
        for (uint32_t padding = covered; padding < offset; padding += 4) {
          if (word_at(bytes, padding) != 0) return false;
        }
        bool xip = runtime == 0x10000000u + offset;
        bool sram = runtime >= 0x20000000u && runtime < 0x20082000u &&
                    length <= 0x20082000u - runtime;
        if (!xip && !sram) return false;
        hash->ranges[i] = {uint32_t(offset), length};
        covered = uint32_t(offset) + length;
      }
      if (covered != start) return false;
    } else if (tag == PICOBIN_BLOCK_ITEM_1BS_HASH_DEF) {
      if (!terminal || !load_map || hash_def || header != 0x01000247) return false;
      hash_def = true;
      // Hash includes the block marker through this complete HASH_DEF item.
      uint32_t hash_words = word_at(bytes, at + 4);
      if (hash_words != (at + 8 - start) / 4) return false;
      hash->block_offset = start;
      hash->block_hash_size = hash_words * 4;
    } else if (tag == PICOBIN_BLOCK_ITEM_HASH_VALUE) {
      if (!hash_def || hash_value || header != 0x94b ||
          at != start + hash->block_hash_size) return false;
      hash_value = true;
      hash->digest_offset = at + 4;
    } else {
      // No signatures, partition tables, alternate entry points, additional
      // image definitions or unknown metadata in the initial OTA format.
      return false;
    }
    at += 4 * words;
  }
  return false;
}

}  // namespace

bool parse_ota_image(const uint8_t* bytes, size_t size, ImageHash* result,
                     const uint8_t* first_sector) {
  if (size < 4096 || size > 4 * 1024 * 1024 || (size & 3)) return false;
  ImageBytes image = {bytes, first_sector};
  uint32_t root = 0;
  bool found = false;
  Block first = {};
  ImageHash unused = {};
  for (uint32_t at = 0; at < 4096; at += 4) {
    if (word_at(image, at) != PICOBIN_BLOCK_MARKER_START) continue;
    // Reject ambiguous or unexpected root markers in the ROM scan window.
    if (found || !parse_block(image, size, at, false, &first, &unused)) return false;
    root = at;
    found = true;
  }
  if (!found || first.end > 4096 || first.next < 4096) return false;
  Block last = {};
  *result = {};
  if (!parse_block(image, size, first.next, true, &last, result)) return false;
  return last.end == size && last.next == root && last.version == first.version;
}

}  // namespace rp2350
}  // namespace toit
#endif
