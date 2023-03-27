// Copyright (C) 2023 Toitware ApS.
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
#include "blake2s.h"

namespace toit {

Blake2s::Blake2s(SimpleResourceGroup* group) : SimpleResource(group), data_(), block_posn_(0), length_(0) {
  h_[0] = 0x6A09E667;
  h_[1] = 0xBB67AE85;
  h_[2] = 0x3C6EF372;
  h_[3] = 0xA54FF53A;
  h_[4] = 0x510E527F;
  h_[5] = 0x9B05688C;
  h_[6] = 0x1F83D9AB;
  h_[7] = 0x5BE0CD19;
}
    
void Blake2s::add(const uint8* contents, intptr_t extra) {
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

// SIGMA constants for Blake2s.
static const uint8 SIGMA[10][16] = {
     0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
     14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3,
     11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4,
     7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8,
     9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13,
     2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9,
     12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11,
     13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10,
     6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5,
     10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0
};

static const uint32 IV[8] = {
  0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
  0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
};

// Rotate right.
#define ROTR32(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

// Mixing function.
#define B2S_G(a, b, c, d, x, y)    \
  v[a] = v[a] + v[b] + x;          \
  v[d] = ROTR32(v[d] ^ v[a], 16);  \
  v[c] = v[c] + v[d];              \
  v[b] = ROTR32(v[b] ^ v[c], 12);  \
  v[a] = v[a] + v[b] + y;          \
  v[d] = ROTR32(v[d] ^ v[a], 8);   \
  v[c] = v[c] + v[d];              \
  v[b] = ROTR32(v[b] ^ v[c], 7);

void Blake2s::process_block() {
  uint32 m[16];
  for (int i = 0; i < 16; i++) {
    m[i] = *reinterpret_cast<uint32*>(data_ + i * 4);
  }
  uint32 v[16];
  for (int i = 0; i < 8; i++) {
    v[i] = h_[i];
    v[i + 8] = IV[i];
  }
  v[12] ^= length_;
  v[13] ^= length_ >> 32;
  v[14] ^= 0xFFFFFFFF;
  for (int i = 0; i < 10; i++) {
    round_(m, v, SIGMA[i * 16 + 0], SIGMA[i * 16 + 1]);
    round_(m, v, SIGMA[i * 16 + 2], SIGMA[i * 16 + 3]);
    round_(m, v, SIGMA[i * 16 + 4], SIGMA[i * 16 + 5]);
    round_(m, v, SIGMA[i * 16 + 6], SIGMA[i * 16 + 7]);
    round_(m, v, SIGMA[i * 16 + 8], SIGMA[i * 16 + 9]);
    round_(m, v, SIGMA[i * 16 + 10], SIGMA[i * 16 + 11]);
    round_(m, v, SIGMA[i * 16 + 12], SIGMA[i * 16 + 13]);
    round_(m, v, SIGMA[i * 16 + 14], SIGMA[i * 16 + 15]);
  }
  for (int i = 0; i < 8; i++) {
    h_[i] ^= v[i] ^ v[i + 8];
  }
}

void Blake2s::round_



































