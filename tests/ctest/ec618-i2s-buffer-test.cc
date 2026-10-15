// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the license in tests/LICENSE.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <initializer_list>

#include "../../src/resources/i2s_buffer_ec618.h"

using toit::I2sBufferFormat;
using toit::I2sBufferCapacity;
using toit::I2sRingFormat;

#define CHECK(condition) do { \
  if (!(condition)) { \
    fprintf(stderr, "line %d: %s\n", __LINE__, #condition); \
    exit(1); \
  } \
} while (0)

static void check_width(int bits, uint32_t left, uint32_t right,
                        const uint8_t* left_bytes, const uint8_t* right_bytes) {
  const int width = bits / 8;
  // Deliberately unaligned, with distinct left/right high bits. This catches
  // accidental native word loads, sign extension and channel swapping.
  uint8_t input[10] = {0};
  memcpy(input + 1, left_bytes, width);
  memcpy(input + 1 + width, right_bytes, width);
  const uint32_t expected[][2] = {
    {left, right}, {left, 0}, {0, right},
    {left, left}, {left, 0}, {0, left},
  };
  for (int slots = 0; slots < 6; slots++) {
    I2sBufferFormat format(bits, slots);
    CHECK(format.frame_bytes() == width * (slots < 3 ? 2 : 1));
    uint32_t actual_left = 0xdeadbeef, actual_right = 0xdeadbeef;
    format.encode(input + 1, &actual_left, &actual_right);
    CHECK(actual_left == expected[slots][0]);
    CHECK(actual_right == expected[slots][1]);
  }

  // Decode two consecutive wire frames into compact output. Each mono read
  // must consume a whole wire frame, with no placeholder for the other slot.
  const int input_slots[] = {0, 4, 5};
  for (int slots : input_slots) {
    I2sBufferFormat format(bits, slots);
    uint8_t output[18];
    memset(output, 0x5a, sizeof(output));
    format.decode(output + 1, left, right);
    format.decode(output + 1 + format.frame_bytes(), right, left);
    CHECK(output[0] == 0x5a);
    for (unsigned i = 1 + 2 * format.frame_bytes(); i < sizeof(output); i++) CHECK(output[i] == 0x5a);
    if (slots == 0) {
      CHECK(memcmp(output + 1, left_bytes, width) == 0);
      CHECK(memcmp(output + 1 + width, right_bytes, width) == 0);
      CHECK(memcmp(output + 1 + 2 * width, right_bytes, width) == 0);
      CHECK(memcmp(output + 1 + 3 * width, left_bytes, width) == 0);
    } else {
      CHECK(memcmp(output + 1, slots == 4 ? left_bytes : right_bytes, width) == 0);
      CHECK(memcmp(output + 1 + width, slots == 4 ? right_bytes : left_bytes, width) == 0);
    }
  }
}

static void check_ring_copy() {
  const unsigned capacity = 18;
  for (int bits : {16, 24, 32}) {
    I2sRingFormat format(bits);
    unsigned width = format.word_bytes();
    for (unsigned index = 0; index < capacity; index++) {
      for (unsigned count = 0; count <= capacity; count++) {
        uint8_t ring[capacity * 4 + 2];
        uint8_t expected[sizeof(ring)];
        uint8_t data[sizeof(ring)];
        uint8_t output[sizeof(ring)];
        memset(ring, 0x5a, sizeof(ring));
        memset(output, 0xa5, sizeof(output));
        for (unsigned i = 0; i < sizeof(data); i++) data[i] = i * 13 + 7;
        memcpy(expected, ring, sizeof(ring));
        // Scalar reference also checks preservation of untouched ring bytes.
        unsigned cursor = index;
        for (unsigned i = 0; i < count; i++) {
          uint32_t sample = 0;
          for (unsigned byte = 0; byte < width; byte++) {
            sample |= uint32_t(data[1 + i * width + byte]) << (byte * 8);
          }
          format.store(expected + 1, cursor, sample);
          if (++cursor == capacity) cursor = 0;
        }
        CHECK(format.copy(ring + 1, capacity, index, data + 1, count, true) == cursor);
        CHECK(memcmp(ring, expected, sizeof(ring)) == 0);
        CHECK(format.copy(ring + 1, capacity, index, output + 1, count, false) == cursor);
        CHECK(output[0] == 0xa5);
        CHECK(memcmp(output + 1, data + 1, count * width) == 0);
        for (unsigned i = 1 + count * width; i < sizeof(output); i++) CHECK(output[i] == 0xa5);
        CHECK(memcmp(ring, expected, sizeof(ring)) == 0);
      }
    }
  }
  for (int bits : {8, 16, 24, 32}) {
    for (int slots = 0; slots < 6; slots++) {
      I2sBufferFormat format(bits, slots);
      for (unsigned width = 2; width <= 4; width++) {
        CHECK(format.matches_ring(width) == (slots == 0 && bits >= 16 && width == unsigned(bits / 8)));
      }
    }
  }
}

int main() {
  check_ring_copy();
  const int ring_widths[] = {8, 16, 24, 32};
  for (int bits : ring_widths) {
    I2sRingFormat ring_format(bits);
    const unsigned width = bits <= 16 ? 2 : bits / 8;
    CHECK(ring_format.word_bytes() == width);
    uint8_t storage[18];
    memset(storage, 0x5a, sizeof(storage));
    const uint32_t samples[] = {0, 0xffffffff, 0x80008000, 0xaabb1234};
    for (unsigned i = 0; i < 4; i++) ring_format.store(storage + 1, i, samples[i]);
    CHECK(storage[0] == 0x5a);
    for (unsigned i = 1 + 4 * width; i < sizeof(storage); i++) CHECK(storage[i] == 0x5a);
    for (unsigned i = 0; i < 4; i++) {
      uint32_t mask = width == 2 ? 0xffff : width == 3 ? 0xffffff : 0xffffffff;
      CHECK(ring_format.load(storage + 1, i) == (samples[i] & mask));
    }
  }
  CHECK(I2sBufferCapacity::ring_words(96000, 0, 1) == 0);
  CHECK(I2sBufferCapacity::ring_words(96000, 0, 5) == 0);
  CHECK(I2sBufferCapacity::ring_words(96000, 0, 3) * 3 == 32640);
  CHECK(I2sBufferCapacity::ring_words(96000, 100, 3) * 3 == 57600);
  CHECK(I2sBufferCapacity::ring_words(16000, 0, 2) * 2 == 12800);
  CHECK(I2sBufferCapacity::ring_words(48000, 0, 2) * 2 == 32768);
  CHECK(I2sBufferCapacity::ring_words(96000, 0, 2) * 2 == 32768);
  CHECK(I2sBufferCapacity::ring_words(96000, 100, 2) * 2 == 38400);
  CHECK(I2sBufferCapacity::ring_words(-1) == 0);
  CHECK(I2sBufferCapacity::ring_words(0) == 0);
  CHECK(I2sBufferCapacity::ring_words(96001) == 0);
  CHECK(I2sBufferCapacity::ring_words(INT32_MAX) == 0);
  CHECK(I2sBufferCapacity::ring_words(16000) * sizeof(uint32_t) == 25600);
  CHECK(I2sBufferCapacity::ring_words(48000) * sizeof(uint32_t) == 32768);
  CHECK(I2sBufferCapacity::ring_words(96000) * sizeof(uint32_t) == 32768);
  CHECK(I2sBufferCapacity::ring_words(48000, 200) * sizeof(uint32_t) == 76800);
  CHECK(I2sBufferCapacity::ring_words(96000, 200) * sizeof(uint32_t) == 153600);
  CHECK(I2sBufferCapacity::ring_words(16000, -1) == 0);
  CHECK(I2sBufferCapacity::ring_words(16000, 1001) == 0);
  CHECK(I2sBufferCapacity::ring_words(16000, INT32_MAX) == 0);
  for (int rate = 1; rate <= 96000; rate++) {
    unsigned compact = I2sBufferCapacity::ring_words(rate, 0, 2);
    unsigned requested_frames = (unsigned(rate) * 200 + 999) / 1000;
    unsigned packed = I2sBufferCapacity::ring_words(rate, 0, 3);
    CHECK(packed >= 1024 && packed * 3 <= 32768);
    CHECK(packed % I2sBufferCapacity::kBlockWords == 0);
    CHECK(packed / 2 >= (requested_frames > 5440 ? 5440 : requested_frames));
    CHECK(packed == 1024 || packed == 10880 || packed / 2 - requested_frames < 64);
    CHECK(compact >= 1024 && compact <= 16384);
    CHECK(compact % I2sBufferCapacity::kBlockWords == 0);
    CHECK(compact / 2 >= (requested_frames > 8192 ? 8192 : requested_frames));
    CHECK(compact == 1024 || compact == 16384 || compact / 2 - requested_frames < 64);
    unsigned words = I2sBufferCapacity::ring_words(rate);
    CHECK(words >= 1024);
    CHECK(words <= I2sBufferCapacity::kDefaultMaximumWords);
    CHECK(words % I2sBufferCapacity::kBlockWords == 0);
    // Independently compute the number of whole stereo frames consumed in
    // 200 ms; no width/slot configuration may reduce the temporal capacity.
    unsigned frames = (unsigned(rate) * 200 + 999) / 1000;
    CHECK(words / 2 >= (frames > 4096 ? 4096 : frames));
    CHECK(words == 1024 || words == 8192 || words / 2 - frames < 64);
    const int durations[] = {1, 50, 200, 1000};
    for (int ms : durations) {
      unsigned explicit_words = I2sBufferCapacity::ring_words(rate, ms);
      unsigned explicit_frames = (unsigned(rate) * unsigned(ms) + 999) / 1000;
      CHECK(explicit_words <= I2sBufferCapacity::kMaximumWords);
      CHECK(explicit_words % I2sBufferCapacity::kBlockWords == 0);
      CHECK(explicit_words / 2 >= explicit_frames);
      CHECK(explicit_words == 1024 || explicit_words / 2 - explicit_frames < 64);
      CHECK(I2sBufferCapacity::ring_words(rate, ms, 2) == explicit_words);
      CHECK(I2sBufferCapacity::ring_words(rate, ms, 3) == explicit_words);
    }
  }
  const uint8_t left8[] = {0x81}, right8[] = {0xe3};
  const uint8_t left16[] = {0x81, 0x92}, right16[] = {0xe3, 0xf4};
  const uint8_t left24[] = {0x81, 0x92, 0xa3}, right24[] = {0xc5, 0xd6, 0xe7};
  const uint8_t left32[] = {0x81, 0x92, 0xa3, 0xb4}, right32[] = {0xc5, 0xd6, 0xe7, 0xf8};
  check_width(8, 0x81, 0xe3, left8, right8);
  check_width(16, 0x9281, 0xf4e3, left16, right16);
  check_width(24, 0xa39281, 0xe7d6c5, left24, right24);
  check_width(32, 0xb4a39281, 0xf8e7d6c5, left32, right32);
  for (int bits = 0; bits <= 40; bits++) {
    CHECK(I2sBufferFormat::valid_bits(bits) == (bits == 8 || bits == 16 || bits == 24 || bits == 32));
  }
  for (int slots = -1; slots <= 6; slots++) {
    CHECK(I2sBufferFormat::valid_input(slots) == (slots == 0 || slots == 4 || slots == 5));
    CHECK(I2sBufferFormat::valid_output(slots) == (slots >= 0 && slots <= 5));
  }
  puts("EC618 I2S buffer formats and capacity bounds PASS");
}
