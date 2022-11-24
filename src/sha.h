// Copyright (C) 2019 Toitware ApS.
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

#include <mbedtls/sha256.h>
#include <mbedtls/sha512.h>

#include "resource.h"
#include "tags.h"
#include "utils.h"

namespace toit {

class Sha : public SimpleResource {
 public:
  TAG(Sha);
  // If you pass null for the group, it is not managed by the SimpleResourceGroup and
  // you must take care of allocating and freeing manually.
  Sha(SimpleResourceGroup* group, int bits);
  virtual ~Sha();

  static const int HASH_LENGTH_224 = 28;
  static const int HASH_LENGTH_256 = 32;
  static const int HASH_LENGTH_384 = 48;
  static const int HASH_LENGTH_512 = 64;

  int hash_length() const { return bits_ >> 3; }

  void add(const uint8* contents, intptr_t extra);
  void get(uint8* hash);

 private:
  int bits_;
  union {
    mbedtls_sha256_context context_;
    mbedtls_sha512_context context_512_;
  };
};

}


