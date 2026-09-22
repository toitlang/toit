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
#include "primitive.h"
#include "process.h"

namespace toit {

Sha::Sha(SimpleResourceGroup* group, int bits)
    : SimpleResource(group)
    , bits_(bits)
    , status_(0) {
  ASSERT(bits == 224 || bits == 256 || bits == 384 || bits == 512);
  if (bits == 224) {
    mbedtls_sha256_init(&context_);
    status_ = mbedtls_sha256_starts_ret(&context_, 1);
  } else if (bits == 256) {
    mbedtls_sha256_init(&context_);
    status_ = mbedtls_sha256_starts_ret(&context_, 0);
  } else if (bits == 384) {
    mbedtls_sha512_init(&context_512_);
    status_ = mbedtls_sha512_starts_ret(&context_512_, 1);
  } else if (bits == 512) {
    mbedtls_sha512_init(&context_512_);
    status_ = mbedtls_sha512_starts_ret(&context_512_, 0);
  }
}

Sha::Sha(const Sha* parent)
    : SimpleResource(static_cast<SimpleResourceGroup*>(parent->resource_group()))
    , bits_(parent->bits_)
    , status_(parent->status_) {
  if (bits_ == 224) {
    mbedtls_sha256_init(&context_);
    mbedtls_sha256_clone(&context_, &parent->context_);
  } else if (bits_ == 256) {
    mbedtls_sha256_init(&context_);
    mbedtls_sha256_clone(&context_, &parent->context_);
  } else if (bits_ == 384) {
    mbedtls_sha512_init(&context_512_);
    mbedtls_sha512_clone(&context_512_, &parent->context_512_);
  } else if (bits_ == 512) {
    mbedtls_sha512_init(&context_512_);
    mbedtls_sha512_clone(&context_512_, &parent->context_512_);
  }
}

Sha::~Sha() {
  if (bits_ <= 256) {
    mbedtls_sha256_free(&context_);
  } else {
    mbedtls_sha512_free(&context_512_);
  }
}

int Sha::add(const uint8* contents, intptr_t extra) {
  if (status_ != 0) return status_;
  if (bits_ <= 256) {
    status_ = mbedtls_sha256_update_ret(&context_, contents, extra);
  } else {
    status_ = mbedtls_sha512_update_ret(&context_512_, contents, extra);
  }
  return status_;
}

int Sha::get(uint8_t* hash) {
  if (status_ != 0) return status_;
  uint8 buffer[64];
  if (bits_ <= 256) {
    status_ = mbedtls_sha256_finish_ret(&context_, buffer);
  } else {
    status_ = mbedtls_sha512_finish_ret(&context_512_, buffer);
  }
  if (status_ != 0) return status_;
  memcpy(hash, buffer, bits_ >> 3);
  return 0;
}

Object* Sha::error(Process* process, int code) {
  if (code == -1) FAIL(MALLOC_FAILED);
  char message[64];
  snprintf(message, sizeof(message), "SHA operation failed (%d)", code);
  String* error = process->allocate_string(message);
  if (error == null) FAIL(ALLOCATION_FAILED);
  return Primitive::mark_as_error(error);
}

}
