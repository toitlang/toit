// Copyright (C) 2022 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#include "utils.h"
#include "siphash.h"

namespace toit {

static inline uint64 read_uint64(const uint8* address) {
  uint64 hi = Utils::read_unaligned_uint32_le(address + 4);
  return (hi << 32) | Utils::read_unaligned_uint32_le(address);
}

Siphash::Siphash(SimpleResourceGroup* group, const uint8* key, int output_length, int c_rounds, int d_rounds)
  : SimpleResource(group)
  , data_()
  , block_posn_(0)
  , c_rounds_(c_rounds)
  , d_rounds_(d_rounds)
  , length_(0)
  , output_length_(output_length) {
  uint64 k0 = read_uint64(key);
  uint64 k1 = read_uint64(key + 8);
  v_[0] = 0x736f6d6570736575 ^ k0;
  v_[1] = 0x646f72616e646f6d ^ k1;
  v_[2] = 0x6c7967656e657261 ^ k0;
  v_[3] = 0x7465646279746573 ^ k1;
  if (output_length == 16) v_[1] ^= 0xee;
  ASSERT(output_length == 8 || output_length == 16);  // Checked in the primitive.
}

static inline uint64 rotl(uint64 in, int distance) {
  return (in << distance) | (in >> (64 - distance));
}

void Siphash::round() {
  uint64 v0 = v_[0];
  uint64 v1 = v_[1];
  uint64 v2 = v_[2];
  uint64 v3 = v_[3];
  v0 += v1;
  v1 = rotl(v1, 13);
  v1 ^= v0;
  v0 = rotl(v0, 32);
  v2 += v3;
  v3 = rotl(v3, 16);
  v3 ^= v2;
  v0 += v3;
  v3 = rotl(v3, 21);
  v_[3] = v3 ^ v0;
  v2 += v1;
  v1 = rotl(v1, 17);
  v_[1] = v1 ^ v2;
  v_[2] = rotl(v2, 32);
  v_[0] = v0;
}

void Siphash::add(const uint8* contents, intptr_t extra) {
  length_ += extra;
  while (extra) {
    intptr_t size = Utils::min<intptr_t>(BLOCK_SIZE - block_posn_, extra);
    memcpy(data_ + block_posn_, contents, size);
    contents += size;
    extra -= size;
    block_posn_ += size;
    if (block_posn_ == BLOCK_SIZE) {
      process_block();
      block_posn_ = 0;
    }
  }
}

void Siphash::get_hash(uint8* hash) {
  memset(data_ + block_posn_, 0, 8 - block_posn_);
  data_[7] = length_;
  process_block();
  if (output_length_ == 16) {
    v_[2] ^= 0xee;
  } else {
    v_[2] ^= 0xff;
  }
  for (int i = 0; i < d_rounds_; i++) round();
  uint64 b = v_[0] ^ v_[1] ^ v_[2] ^ v_[3];
  Utils::write_unaligned_uint32_le(hash, b);
  Utils::write_unaligned_uint32_le(hash + 4, b >> 32);
  if (output_length_ == 8) return;
  v_[1] ^= 0xdd;
  for (int i = 0; i < d_rounds_; i++) {
    round();
  }
  b = v_[0] ^ v_[1] ^ v_[2] ^ v_[3];
  Utils::write_unaligned_uint32_le(hash + 8, b);
  Utils::write_unaligned_uint32_le(hash + 12, b >> 32);
}

void Siphash::process_block() {
  v_[3] ^= read_uint64(data_);
  for (int i = 0; i < c_rounds_; i++) round();
  block_posn_ = 0;
  v_[0] ^= read_uint64(data_);
}

}
