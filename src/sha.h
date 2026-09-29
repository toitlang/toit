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

#define MBEDTLS_ALLOW_PRIVATE_ACCESS
#include <mbedtls/sha256.h>
#include <mbedtls/sha512.h>
#if MBEDTLS_VERSION_MAJOR >= 3
// Bring back the _ret names for sha functions.
#include <mbedtls/compat-2.x.h>
#endif

#include "top.h"
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
  Sha(const Sha* parent);
  virtual ~Sha();

  static const int HASH_LENGTH_224 = 28;
  static const int HASH_LENGTH_256 = 32;
  static const int HASH_LENGTH_384 = 48;
  static const int HASH_LENGTH_512 = 64;

  int hash_length() const { return bits_ >> 3; }

  // The mbedtls SHA backend can fail. On ESP32 the IDF DMA implementation
  // reports allocation failure as ESP_FAIL (-1). Once any operation has
  // failed, the context is unusable and every later call reports the same
  // error. Callers must check the results.
  int status() const { return status_; }
  [[nodiscard]] int add(const uint8* contents, intptr_t extra);
  [[nodiscard]] int get(uint8* hash);
  // Converts a backend error into a primitive error result. -1 (ESP_FAIL)
  // becomes MALLOC_FAILED so the GC retry path applies.
  static Object* error(Process* process, int code);

 private:
  int bits_;
  int status_;
  union {
    mbedtls_sha256_context context_;
    mbedtls_sha512_context context_512_;
  };
};

}

