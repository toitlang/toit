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
  , _data()
  , _block_posn(0)
  , _c_rounds(c_rounds)
  , _d_rounds(d_rounds)
  , _length(0)
  , _output_length(output_length) {
  uint64 k0 = read_uint64(key);
  uint64 k1 = read_uint64(key + 8);
  _v[0] = 0x736f6d6570736575 ^ k0;
  _v[1] = 0x646f72616e646f6d ^ k1;
  _v[2] = 0x6c7967656e657261 ^ k0;
  _v[3] = 0x7465646279746573 ^ k1;
  if (output_length == 16) _v[1] ^= 0xee;
  ASSERT(output_length == 8 || output_length == 16);
}

static inline uint64 rotl(uint64 in, int distance) {
  return (in << distance) | (in >> (64 - distance));
}

void Siphash::round() {
  uint64 v0 = _v[0];
  uint64 v1 = _v[1];
  uint64 v2 = _v[2];
  uint64 v3 = _v[3];
  v0 += v1;
  v1 = rotl(v1, 13);
  v1 ^= v0;
  v0 = rotl(v0, 32);
  v2 += v3;
  v3 = rotl(v3, 16);
  v3 ^= v2;
  v0 += v3;
  v3 = rotl(v3, 21);
  _v[3] = v3 ^ v0;
  v2 += v1;
  v1 = rotl(v1, 17);
  _v[1] = v1 ^ v2;
  _v[2] = rotl(v2, 32);
  _v[0] = v0;
}

void Siphash::add(const uint8* contents, intptr_t extra) {
  _length += extra;
  while (extra) {
    intptr_t size = Utils::min<intptr_t>(BLOCK_SIZE - _block_posn, extra);
    memcpy(_data + _block_posn, contents, size);
    contents += size;
    extra -= size;
    _block_posn += size;
    if (_block_posn == BLOCK_SIZE) {
      process_block();
      _block_posn = 0;
    }
  }
}

void Siphash::get_hash(uint8* hash) {
  memset(_data + _block_posn, 0, 8 - _block_posn);
  _data[7] = _length;
  process_block();
  if (_output_length == 16) {
    _v[2] ^= 0xee;
  } else {
    _v[2] ^= 0xff;
  }
  for (int i = 0; i < _d_rounds; i++) round();
  uint64 b = _v[0] ^ _v[1] ^ _v[2] ^ _v[3];
  Utils::write_unaligned_uint32_le(hash, b);
  Utils::write_unaligned_uint32_le(hash + 4, b >> 32);
  if (_output_length == 8) return;
  _v[1] ^= 0xdd;
  for (int i = 0; i < _d_rounds; i++) {
    round();
  }
  b = _v[0] ^ _v[1] ^ _v[2] ^ _v[3];
  Utils::write_unaligned_uint32_le(hash + 8, b);
  Utils::write_unaligned_uint32_le(hash + 12, b >> 32);
}

void Siphash::process_block() {
  _v[3] ^= read_uint64(_data);
  for (int i = 0; i < _c_rounds; i++) round();
  _block_posn = 0;
  _v[0] ^= read_uint64(_data);
}

}
