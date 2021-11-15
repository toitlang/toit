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

#pragma once

#include "resource.h"

namespace toit {

class Sha1 : public SimpleResource {
 public:
  TAG(Sha1);
  Sha1(SimpleResourceGroup* group);

  void add(const uint8* contents, intptr_t extra);
  void get_hash(uint8* hash);

 private:
  static const uint32_t BLOCK_SIZE = 64;
  static const uint32_t BLOCK_MASK = BLOCK_SIZE - 1;

  void process_block();

  inline uint32_t get_big_endian_word(int byte_index) {
    return
      (_data[byte_index + 0] << 24) |
      (_data[byte_index + 1] << 16) |
      (_data[byte_index + 2] << 8) |
      (_data[byte_index + 3] << 0);
  }

  uint8 _data[BLOCK_SIZE];
  uint32_t _h[5];
  uint32_t _block_posn;
  intptr_t _length;
};

}

