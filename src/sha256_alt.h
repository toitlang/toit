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

#ifdef MBEDTLS_SHA256_ALT

#ifdef __cplusplus
extern "C" {
#endif

#define SHA_BLOCK_LEN ((size_t)64)

typedef struct {
  int bit_length;  // 224 or 256.
  uint8_t pending[SHA_BLOCK_LEN];
  size_t pending_fullness;
  uint32_t state[8];
  uint64_t length;  // In bits.
} mbedtls_sha256_context;

#ifdef __cplusplus
}
#endif

#endif  // MBEDTLS_SHA256_ALT
