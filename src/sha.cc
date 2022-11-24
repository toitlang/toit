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

#include "sha.h"

namespace toit {

Sha::Sha(SimpleResourceGroup* group, int bits)
    : SimpleResource(group)
    , bits_(bits) {
  if (bits == 160) {
    mbedtls_sha1_init(&context_1_);
    mbedtls_sha1_starts_ret(&context_1_);
  } else if (bits == 224) {
    mbedtls_sha256_init(&context_);
    mbedtls_sha256_starts_ret(&context_, 1);
  } else if (bits == 256) {
    mbedtls_sha256_init(&context_);
    mbedtls_sha256_starts_ret(&context_, 0);
  } else if (bits == 384) {
    mbedtls_sha512_init(&context_512_);
    mbedtls_sha512_starts_ret(&context_512_, 1);
  } else if (bits == 512) {
    mbedtls_sha512_init(&context_512_);
    mbedtls_sha512_starts_ret(&context_512_, 0);
  }
}

Sha::~Sha() {
  if (bits_ == 160) {
    mbedtls_sha1_free(&context_1_);
  } else if (bits_ <= 256) {
    mbedtls_sha256_free(&context_);
  } else {
    mbedtls_sha512_free(&context_512_);
  }
}

void Sha::add(const uint8* contents, intptr_t extra) {
  if (bits_ == 160) {
    mbedtls_sha1_update_ret(&context_1_, contents, extra);
  } else if (bits_ <= 256) {
    mbedtls_sha256_update_ret(&context_, contents, extra);
  } else {
    mbedtls_sha512_update_ret(&context_512_, contents, extra);
  }
}

void Sha::get(uint8_t* hash) {
  uint8 buffer[64];
  if (bits_ == 160) {
    mbedtls_sha1_finish_ret(&context_1_, buffer);
  } else if (bits_ <= 256) {
    mbedtls_sha256_finish_ret(&context_, buffer);
  } else {
    mbedtls_sha512_finish_ret(&context_512_, buffer);
  }
  memcpy(hash, buffer, bits_ >> 3);
}

}
