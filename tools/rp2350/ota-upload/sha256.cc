// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.

#include "sha256.h"

#include <string.h>

namespace {

const uint32_t kRoundConstants[64] = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

uint32_t rotate_right(uint32_t value, int count) {
  return (value >> count) | (value << (32 - count));
}

}  // namespace

Sha256::Sha256()
    : byte_count_(0)
    , pending_length_(0) {
  state_[0] = 0x6a09e667;
  state_[1] = 0xbb67ae85;
  state_[2] = 0x3c6ef372;
  state_[3] = 0xa54ff53a;
  state_[4] = 0x510e527f;
  state_[5] = 0x9b05688c;
  state_[6] = 0x1f83d9ab;
  state_[7] = 0x5be0cd19;
}

void Sha256::update(const uint8_t* data, size_t length) {
  byte_count_ += length;
  while (length != 0) {
    size_t available = sizeof(pending_) - pending_length_;
    size_t amount = length < available ? length : available;
    memcpy(pending_ + pending_length_, data, amount);
    pending_length_ += amount;
    data += amount;
    length -= amount;
    if (pending_length_ == sizeof(pending_)) {
      transform(pending_);
      pending_length_ = 0;
    }
  }
}

void Sha256::finish(uint8_t digest[32]) {
  uint64_t bit_count = byte_count_ * 8;
  uint8_t terminator = 0x80;
  update(&terminator, 1);
  uint8_t zeroes[64] = {};
  size_t padding = pending_length_ <= 56
      ? 56 - pending_length_
      : 64 + 56 - pending_length_;
  update(zeroes, padding);
  uint8_t length_bytes[8];
  for (int i = 7; i >= 0; i--) {
    length_bytes[i] = static_cast<uint8_t>(bit_count);
    bit_count >>= 8;
  }
  update(length_bytes, sizeof(length_bytes));

  for (int i = 0; i < 8; i++) {
    digest[i * 4] = static_cast<uint8_t>(state_[i] >> 24);
    digest[i * 4 + 1] = static_cast<uint8_t>(state_[i] >> 16);
    digest[i * 4 + 2] = static_cast<uint8_t>(state_[i] >> 8);
    digest[i * 4 + 3] = static_cast<uint8_t>(state_[i]);
  }
}

void Sha256::transform(const uint8_t block[64]) {
  uint32_t words[64];
  for (int i = 0; i < 16; i++) {
    words[i] = (static_cast<uint32_t>(block[i * 4]) << 24) |
        (static_cast<uint32_t>(block[i * 4 + 1]) << 16) |
        (static_cast<uint32_t>(block[i * 4 + 2]) << 8) |
        static_cast<uint32_t>(block[i * 4 + 3]);
  }
  for (int i = 16; i < 64; i++) {
    uint32_t x = words[i - 15];
    uint32_t y = words[i - 2];
    uint32_t sigma0 = rotate_right(x, 7) ^ rotate_right(x, 18) ^ (x >> 3);
    uint32_t sigma1 = rotate_right(y, 17) ^ rotate_right(y, 19) ^ (y >> 10);
    words[i] = words[i - 16] + sigma0 + words[i - 7] + sigma1;
  }

  uint32_t a = state_[0];
  uint32_t b = state_[1];
  uint32_t c = state_[2];
  uint32_t d = state_[3];
  uint32_t e = state_[4];
  uint32_t f = state_[5];
  uint32_t g = state_[6];
  uint32_t h = state_[7];
  for (int i = 0; i < 64; i++) {
    uint32_t sum1 = rotate_right(e, 6) ^ rotate_right(e, 11) ^ rotate_right(e, 25);
    uint32_t choose = (e & f) ^ (~e & g);
    uint32_t temporary1 = h + sum1 + choose + kRoundConstants[i] + words[i];
    uint32_t sum0 = rotate_right(a, 2) ^ rotate_right(a, 13) ^ rotate_right(a, 22);
    uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
    uint32_t temporary2 = sum0 + majority;
    h = g;
    g = f;
    f = e;
    e = d + temporary1;
    d = c;
    c = b;
    b = a;
    a = temporary1 + temporary2;
  }
  state_[0] += a;
  state_[1] += b;
  state_[2] += c;
  state_[3] += d;
  state_[4] += e;
  state_[5] += f;
  state_[6] += g;
  state_[7] += h;
}
