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

#pragma once

#include "resource.h"

namespace toit {

class Siphash : public SimpleResource {
 public:
  TAG(Siphash);
  // Key is a pointer to a 16 byte random key.
  // Output_length is 8 or 16.
  Siphash(SimpleResourceGroup* group, const uint8* key, int output_length, int c_rounds, int d_rounds);

  void add(const uint8* contents, intptr_t extra);
  void get_hash(uint8* hash);
  int output_length() { return output_length_; }

 private:
  static const uint32_t BLOCK_SIZE = 8;
  static const uint32_t BLOCK_MASK = BLOCK_SIZE - 1;

  void round();
  void process_block();

  uint8 data_[BLOCK_SIZE];
  uint64_t v_[4];
  int block_posn_;
  int c_rounds_;
  int d_rounds_;
  uword length_;
  int output_length_;
};

}

