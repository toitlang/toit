// Copyright (C) 2024 Toitware ApS.
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

class Blake2s : public SimpleResource {
 public:
  TAG(Blake2s);
  Blake2s(SimpleResourceGroup* group, int key_bytes, int hash_bytes);

  void add(const uint8* contents, intptr_t extra);
  void get_hash(uint8* hash);

  void clone(Blake2s* child) {
    memcpy(child->data_, data_, BLOCK_SIZE);
    memcpy(child->h_, h_, sizeof(h_));
    child->block_posn_ = block_posn_;
    child->length_ = length_;
  }

  static const word BLOCK_SIZE = 64;
  static const word MAX_HASH_SIZE = 32;

 private:
  static const uint32_t BLOCK_MASK = BLOCK_SIZE - 1;

  void process_block(bool last);

  uint8 data_[BLOCK_SIZE];
  uint32_t h_[8];
  uint32_t block_posn_ = 0;
  uint64_t length_ = 0;
};

}
