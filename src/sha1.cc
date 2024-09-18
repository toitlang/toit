// Copyright (C) 2018 Toitware ApS.
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
#include "sha1.h"

namespace toit {

Sha1::Sha1(SimpleResourceGroup* group) : SimpleResource(group), data_(), block_posn_(0), length_(0) {
  h_[0] = 0x67452301;
  h_[1] = 0xEFCDAB89;
  h_[2] = 0x98BADCFE;
  h_[3] = 0x10325476;
  h_[4] = 0xC3D2E1F0;
}

void Sha1::add(const uint8* contents, intptr_t extra) {
  length_ += extra;
  while (extra) {
    intptr_t end = Utils::min<intptr_t>(BLOCK_SIZE, block_posn_ + extra);
    intptr_t size = end - block_posn_;
    memcpy(data_ + block_posn_, contents, size);
    contents += size;
    extra -= size;
    block_posn_ = end;
    if (block_posn_ == BLOCK_SIZE) {
      process_block();
      block_posn_ = 0;
    }
  }
}

void Sha1::get_hash(uint8* hash) {
  int64_t original_length = length_ * 8;  // In bits.
  uint8 terminator = 0x80;
  add(&terminator, 1);
  intptr_t remaining = BLOCK_SIZE - block_posn_;
  memset(data_ + block_posn_, 0, remaining);
  if (remaining < 8) {
    process_block();
    memset(data_, 0, BLOCK_SIZE);
  }
  for (int i = 0; i < 8; i++) data_[BLOCK_SIZE - 1 - i] = original_length >> (i << 3);
  process_block();
  for (int i = 0; i < 5; i++) {
    hash[i * 4 + 0] = (h_[i] >> 24) & 0xff;
    hash[i * 4 + 1] = (h_[i] >> 16) & 0xff;
    hash[i * 4 + 2] = (h_[i] >> 8) & 0xff;
    hash[i * 4 + 3] = (h_[i] >> 0) & 0xff;
  }
}

void Sha1::process_block() {
  uint32_t w[80];
  for (int i = 0; i < 16; i++) w[i] = get_big_endian_word(i << 2);
  for (int i = 16; i < 80; i++) {
    uint32_t n = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]);
    w[i] = (n << 1) | (n >> 31);
  }

  uint32_t a = h_[0];
  uint32_t b = h_[1];
  uint32_t c = h_[2];
  uint32_t d = h_[3];
  uint32_t e = h_[4];

  for (int i = 0; i < 80; i++) {
    uint32_t f = 0;
    uint32_t k = 0;
    if (i < 20) {
      f = (b & c) | ((~b) & d);
      k = 0x5A827999;
    } else if (i < 40) {
      f = b ^ c ^ d;
      k = 0x6ED9EBA1;
    } else if (i < 60) {
      f = (b & c) | (b & d) | (c & d);
      k = 0x8F1BBCDC;
    } else {
      f = b ^ c ^ d;
      k = 0xCA62C1D6;
    }

    uint32_t temp = ((a << 5) | (a >> 27)) + f + e + k + w[i];
    e = d;
    d = c;
    c = (b << 30) | (b >> 2);
    b = a;
    a = temp;
  }

  h_[0] += a;
  h_[1] += b;
  h_[2] += c;
  h_[3] += d;
  h_[4] += e;
}

}
