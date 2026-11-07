// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "update.h"
#include <assert.h>
#include <setjmp.h>
#include <stdio.h>
#include <string.h>

static uint8_t flash[0x200000];
static uint8_t saved[sizeof(flash)];
static jmp_buf power_loss;
static int cut_at = -1;
static int operation;
static int cut_part;

const uint8_t* update_read(uint32_t offset) {
  assert(offset < sizeof(flash));
  return flash + offset;
}

static bool change(uint32_t offset, const uint8_t* data, unsigned size) {
  // A write to the loader, or outside the actual chip, fails the test.
  assert(offset >= UPDATE_INSTALLED && offset <= sizeof(flash) - size);
  assert((offset & (size - 1)) == 0);
  bool cut = operation++ == cut_at;
  unsigned count = cut ? (unsigned)cut_part * size / 2 : size;
  for (unsigned i = 0; i < count; i++) {
    if (data) {
      assert((flash[offset + i] & data[i]) == data[i]);
      flash[offset + i] &= data[i];
    } else {
      flash[offset + i] = 0xff;
    }
  }
  if (cut) longjmp(power_loss, 1);
  return true;
}

bool update_erase(uint32_t offset) {
  return change(offset, NULL, UPDATE_SECTOR);
}

bool update_program(uint32_t offset, const uint8_t* page) {
  return change(offset, page, UPDATE_PAGE);
}

static UpdateImage prepare(unsigned version) {
  uint8_t bytes[UPDATE_SECTOR * 2];
  memset(bytes, version, sizeof(bytes));
  uint32_t vectors[] = {0x20042000, 0x10000000 + UPDATE_APP + 0x201};
  memcpy(bytes + 256, vectors, sizeof(vectors));
  UpdateImage image = {UPDATE_MAGIC, 1, sizeof(bytes) - 31, 0, version, 0};
  image.crc = update_crc(bytes, image.size);
  image.header_crc = update_crc(&image, offsetof(UpdateImage, header_crc));
  assert(update_begin());
  assert(update_stage(0, bytes));
  assert(update_stage(UPDATE_SECTOR, bytes + UPDATE_SECTOR));
  return image;
}

static void verify(unsigned version) {
  UpdateImage image;
  assert(update_installed(&image));
  assert(image.version == version);
  for (unsigned i = 0; i < UPDATE_INSTALLED; i++) assert(flash[i] == 0xa5);
}

int main(void) {
  assert(update_crc("123456789", 9) == 0xcbf43926);
  memset(flash, 0xff, sizeof(flash));
  memset(flash, 0xa5, UPDATE_INSTALLED);
  UpdateImage first = prepare(1);
  assert(update_commit(&first));
  assert(update_install());
  verify(1);
  memcpy(saved, flash, sizeof(flash));

  // Interrupt every erase/program during download, descriptor commit and
  // installation: before, halfway through, and after the operation.
  operation = 0;
  UpdateImage second = prepare(2);
  assert(update_commit(&second));
  assert(update_install());
  int total = operation;
  for (cut_part = 0; cut_part <= 2; cut_part++) {
    for (cut_at = 0; cut_at < total; cut_at++) {
      memcpy(flash, saved, sizeof(flash));
      operation = 0;
      if (!setjmp(power_loss)) {
        second = prepare(2);
        assert(update_commit(&second));
        assert(update_install());
        assert(!"Power failure was not reached");
      }
      int previous_cut = cut_at;
      cut_at = -1;
      assert(update_install());
      UpdateImage installed;
      assert(update_installed(&installed));
      assert(installed.version == 1 || installed.version == 2);
      verify(installed.version);
      // A fresh upload must also work after every interrupted attempt.
      second = prepare(2);
      assert(update_commit(&second));
      assert(update_install());
      verify(2);
      cut_at = previous_cut;
    }
  }
  cut_at = -1;
  second = prepare(3);
  int before = operation;
  assert(!update_stage(UPDATE_CAPACITY, flash));
  assert(!update_stage(UINT32_MAX, flash));
  assert(!update_stage(1, flash));
  second.size = UINT32_MAX;
  second.header_crc = update_crc(&second, offsetof(UpdateImage, header_crc));
  assert(!update_commit(&second));
  assert(operation == before);
  second = prepare(3);
  flash[UPDATE_STAGE + 300] ^= 1;
  assert(!update_commit(&second));
  verify(2);
  second = prepare(3);
  assert(update_commit(&second));
  flash[UPDATE_STAGE + 300] ^= 1;
  assert(!update_install());
  verify(2);
  printf("PASS: %d interrupted updates, recovery, bounds and corruption checks\n", total * 3);
}
