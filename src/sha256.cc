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

#include "sha256.h"

namespace toit {

Sha256::Sha256(SimpleResourceGroup* group) : SimpleResource(group) {
  mbedtls_sha256_init(&context_);
  static const int SHA256 = 0;
  mbedtls_sha256_starts_ret(&context_, SHA256);
}

Sha256::~Sha256() {
  mbedtls_sha256_free(&context_);
}

void Sha256::add(const uint8* contents, intptr_t extra) {
  mbedtls_sha256_update_ret(&context_, contents, extra);
}

void Sha256::get(uint8_t* hash) {
  mbedtls_sha256_finish_ret(&context_, hash);
}

}
