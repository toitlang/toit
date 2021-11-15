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

#include "resource.h"
#include "tags.h"
#include "utils.h"

namespace toit {

class Sha256 : public SimpleResource {
 public:
  TAG(Sha256);
  // If you pass null for the group, it is not managed by the SimpleResourceGroup and
  // you must take care of allocating and freeing manually.
  Sha256(SimpleResourceGroup* group);
  virtual ~Sha256();

  static const int HASH_LENGTH = 32;  // 32 bytes.

  void add(const uint8* contents, intptr_t extra);
  void get(uint8* hash);

 private:
  mbedtls_sha256_context _context;
};

}


