// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the license in the LICENSE file.

#pragma once

#include <stdint.h>
#include <string.h>

namespace toit {

// Application writes have been delayed for up to 136 ms on the modem rig.
// Aim for 200 ms by default, bounded to 32 KB per direction. Explicit
// durations are never capped: insufficient memory must fail configuration.
// Counts are logical FIFO words. Compact rings store 8/16-bit samples in
// 16 bits; the DMA blocks still use two unpacked 32-bit words per frame.
struct I2sBufferCapacity {
  static constexpr unsigned kBlockWords = 128;
  static constexpr unsigned kMinimumWords = 1024;
  static constexpr unsigned kDefaultMaximumBytes = 32768;
  static constexpr unsigned kDefaultMaximumWords = kDefaultMaximumBytes / 4;
  static constexpr unsigned kMaximumWords = 192000;  // 1 second at 96 kHz.

  static unsigned ring_words(int rate, int duration_ms = 0, unsigned word_bytes = 4) {
    if (rate <= 0 || rate > 96000 || duration_ms < 0 || duration_ms > 1000) return 0;
    if (word_bytes != 2 && word_bytes != 4) return 0;
    unsigned ms = duration_ms == 0 ? 200 : unsigned(duration_ms);
    unsigned blocks = (unsigned(rate) * ms + 63999) / 64000;
    unsigned words = blocks * kBlockWords;
    unsigned maximum_words = kDefaultMaximumBytes / word_bytes;
    if (duration_ms == 0 && words > maximum_words) words = maximum_words;
    return words < kMinimumWords ? kMinimumWords : words;
  }
};

// Keep the unused high FIFO bits out of software storage. memcpy avoids
// alignment and aliasing assumptions while compiling to native narrow loads
// and stores on the EC618. Indexes and DMA accounting remain in FIFO words.
class I2sRingFormat {
 public:
  explicit I2sRingFormat(int bits = 32) : word_bytes_(bits <= 16 ? 2 : 4) {}

  unsigned word_bytes() const { return word_bytes_; }

  uint32_t load(const uint8_t* ring, unsigned index) const {
    if (word_bytes_ == 2) {
      uint16_t result;
      memcpy(&result, ring + index * 2, sizeof(result));
      return result;
    }
    uint32_t result;
    memcpy(&result, ring + index * 4, sizeof(result));
    return result;
  }

  void store(uint8_t* ring, unsigned index, uint32_t value) const {
    if (word_bytes_ == 2) {
      uint16_t narrow = static_cast<uint16_t>(value);
      memcpy(ring + index * 2, &narrow, sizeof(narrow));
    } else {
      memcpy(ring + index * 4, &value, sizeof(value));
    }
  }

 private:
  unsigned word_bytes_;
};

// The peripheral always transfers two unpacked FIFO words per stereo frame.
// Translate the public, little-endian sample buffers at the ring boundary.
// Slot numbers match lib/i2s.toit, including zero-filled unselected TX slots.
class I2sBufferFormat {
 public:
  enum Slots { STEREO_BOTH, STEREO_LEFT, STEREO_RIGHT, MONO_BOTH, MONO_LEFT, MONO_RIGHT };

  I2sBufferFormat(int bits = 0, int slots = STEREO_BOTH)
    : sample_bytes_(bits / 8), slots_(slots) {}

  static bool valid_bits(int bits) {
    return bits == 8 || bits == 16 || bits == 24 || bits == 32;
  }

  static bool valid_input(int slots) {
    return slots == STEREO_BOTH || slots == MONO_LEFT || slots == MONO_RIGHT;
  }

  static bool valid_output(int slots) {
    return slots >= STEREO_BOTH && slots <= MONO_RIGHT;
  }

  int frame_bytes() const { return sample_bytes_ * (slots_ <= STEREO_RIGHT ? 2 : 1); }

  void encode(const uint8_t* data, uint32_t* left, uint32_t* right) const {
    uint32_t first = load(data);
    if (slots_ <= STEREO_RIGHT) {
      *left = slots_ == STEREO_RIGHT ? 0 : first;
      *right = slots_ == STEREO_LEFT ? 0 : load(data + sample_bytes_);
    } else {
      *left = slots_ == MONO_RIGHT ? 0 : first;
      *right = slots_ == MONO_LEFT ? 0 : first;
    }
  }

  void decode(uint8_t* data, uint32_t left, uint32_t right) const {
    store(data, slots_ == MONO_RIGHT ? right : left);
    if (slots_ == STEREO_BOTH) store(data + sample_bytes_, right);
  }

 private:
  uint32_t load(const uint8_t* data) const {
    uint32_t sample = 0;
    for (int i = 0; i < sample_bytes_; i++) sample |= uint32_t(data[i]) << (8 * i);
    return sample;
  }

  void store(uint8_t* data, uint32_t sample) const {
    for (int i = 0; i < sample_bytes_; i++) data[i] = sample >> (8 * i);
  }

  int sample_bytes_;
  int slots_;
};

}  // namespace toit
