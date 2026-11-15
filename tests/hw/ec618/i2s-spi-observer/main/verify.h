// Copyright (C) 2026 Toit contributors.
// Private diagnostic; use of this source is governed by tests/LICENSE.
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#ifdef ESP_PLATFORM
#include "esp_attr.h"
#define VERIFY_IRAM IRAM_ATTR
#else
#define VERIFY_IRAM
#endif

enum { VERIFY_RECORDS = 64 };
typedef struct { uint32_t frame, left, right; } VerifyError;
typedef struct {
  unsigned bits, training, seen;
  bool started, invalid;
  uint32_t frames, errors, first_frame, first_left, first_right;
  VerifyError records[VERIFY_RECORDS];
} Verify;

static uint32_t VERIFY_IRAM sample(unsigned frame, bool right, unsigned bits) {
  uint32_t base = right ? 0xe3ba9876u : 0x81234567u;
  uint32_t index = right ? (frame * 73 + 19) % 251 : frame;
  uint32_t mask = bits == 32 ? UINT32_MAX : (1u << bits) - 1;
  return (base ^ (index * 0x01010101u) ^ UINT32_MAX) & mask;
}

static void verify_init(Verify *v, unsigned bits) {
  memset(v, 0, sizeof(*v));
  v->bits = bits;
  v->invalid = bits != 16 && bits != 24 && bits != 32;
}

static void VERIFY_IRAM verify_data(Verify *v, const uint8_t *data, size_t size) {
  if (v->invalid) return;
  unsigned width = v->bits / 8;
  if (size % (width * 2)) { v->invalid = true; return; }
  for (size_t offset = 0; offset < size; offset += width * 2) {
    uint32_t left = 0, right = 0;
    for (unsigned i = 0; i < width; i++) {
      left |= (uint32_t)data[offset + i] << (8 * i);
      right |= (uint32_t)data[offset + width + i] << (8 * i);
    }
    if (!v->started) {
      // Match the bounded startup allowance in the permanent fixture.
      bool first = v->seen++ == 0;
      if (!left && !right) {
        if (++v->training > 8) v->invalid = true;
        continue;
      }
      if (first) continue;
      if (v->training < 7 || left != sample(0, false, v->bits) ||
          right != sample(0, true, v->bits)) {
        v->invalid = true;
        return;
      }
      v->started = true;
    }
    unsigned phase = v->frames % 251;
    if (left != sample(phase, false, v->bits) || right != sample(phase, true, v->bits)) {
if (v->errors < VERIFY_RECORDS) {
  VerifyError *record = &v->records[v->errors];
  record->frame = v->frames;
  record->left = left;
  record->right = right;
}
if (v->errors++ == 0) {
        v->first_frame = v->frames;
        v->first_left = left;
        v->first_right = right;
      }
    }
    v->frames++;
  }
}
