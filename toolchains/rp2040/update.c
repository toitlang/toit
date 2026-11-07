// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "update.h"
#include <string.h>

uint32_t update_crc(const void* data, size_t size) {
  const uint8_t* bytes = data;
  uint32_t crc = UINT32_MAX;
  while (size--) {
    crc ^= *bytes++;
    for (unsigned bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1)));
    }
  }
  return ~crc;
}

bool update_descriptor_valid(const UpdateImage* image) {
  return image->magic == UPDATE_MAGIC && image->format == 1 &&
      image->size >= 264 && image->size <= UPDATE_CAPACITY &&
      image->header_crc == update_crc(image, offsetof(UpdateImage, header_crc));
}

bool update_image_valid(uint32_t offset, const UpdateImage* image) {
  if ((offset != UPDATE_APP && offset != UPDATE_STAGE) ||
      !update_descriptor_valid(image)) return false;
  const uint8_t* data = update_read(offset);
  uint32_t vectors[2];
  memcpy(vectors, data + 256, sizeof(vectors));
  // Both stored copies are linked for the application address. Check the initial
  // stack and Thumb reset vector before any application is made bootable.
  return vectors[0] > 0x20000000u && vectors[0] <= 0x20042000u &&
      (vectors[0] & 7) == 0 && (vectors[1] & 1) != 0 &&
      vectors[1] >= 0x10000000u + UPDATE_APP + 264 &&
      vectors[1] < 0x10000000u + UPDATE_APP + image->size &&
      update_crc(data, image->size) == image->crc;
}

bool update_installed(UpdateImage* image) {
  memcpy(image, update_read(UPDATE_INSTALLED), sizeof(*image));
  return update_image_valid(UPDATE_APP, image);
}

bool update_begin(void) {
  // Invalidate a previous staged update before modifying any of its bytes.
  return update_erase(UPDATE_PENDING);
}

bool update_stage(uint32_t offset, const uint8_t* sector) {
  if ((offset & (UPDATE_SECTOR - 1)) || offset >= UPDATE_CAPACITY) return false;
  if (!update_erase(UPDATE_STAGE + offset)) return false;
  for (unsigned at = 0; at < UPDATE_SECTOR; at += UPDATE_PAGE) {
    if (!update_program(UPDATE_STAGE + offset + at, sector + at)) return false;
  }
  return memcmp(update_read(UPDATE_STAGE + offset), sector, UPDATE_SECTOR) == 0;
}

static bool write_descriptor(uint32_t offset, const UpdateImage* image) {
  uint8_t page[UPDATE_PAGE];
  memset(page, 0xff, sizeof(page));
  memcpy(page, image, sizeof(*image));
  return update_erase(offset) && update_program(offset, page) &&
      memcmp(update_read(offset), page, sizeof(page)) == 0;
}

bool update_commit(const UpdateImage* image) {
  return update_image_valid(UPDATE_STAGE, image) &&
      write_descriptor(UPDATE_PENDING, image);
}

bool update_install(void) {
  UpdateImage image;
  memcpy(&image, update_read(UPDATE_PENDING), sizeof(image));
  if (!update_descriptor_valid(&image)) return true;
  if (!update_image_valid(UPDATE_STAGE, &image)) return false;
  // Keep the staged descriptor until the installed descriptor and every byte
  // have been verified. A reset anywhere in this sequence retries the copy.
  if (!update_erase(UPDATE_INSTALLED)) return false;
  // Installation is single-threaded at boot. Keep the transfer buffer out of
  // the RP2040's small startup stack.
  static uint8_t sector[UPDATE_SECTOR];
  for (uint32_t offset = 0; offset < image.size; offset += UPDATE_SECTOR) {
    memcpy(sector, update_read(UPDATE_STAGE + offset), sizeof(sector));
    if (!update_erase(UPDATE_APP + offset)) return false;
    for (unsigned at = 0; at < UPDATE_SECTOR; at += UPDATE_PAGE) {
      if (!update_program(UPDATE_APP + offset + at, sector + at)) return false;
    }
  }
  return update_image_valid(UPDATE_APP, &image) &&
      write_descriptor(UPDATE_INSTALLED, &image) && update_erase(UPDATE_PENDING);
}
