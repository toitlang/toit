// Copyright (C) 2020 Toitware ApS.
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

#include "top.h"

#include <mbedtls/aes.h>

#include "resource.h"
#include "tags.h"

namespace toit {

class AesEcbContext : public SimpleResource {
 public:
  TAG(AesEcbContext);
  AesEcbContext(SimpleResourceGroup* group, const Blob* key, bool encrypt);
  virtual ~AesEcbContext();

  mbedtls_aes_context context_;
};

class AesCbcContext : public AesEcbContext {
 public:
  TAG(AesCbcContext);
  AesCbcContext(SimpleResourceGroup* group, const Blob* key, const uint8* iv, bool encrypt);

  uint8 iv_[16];
};

}

#ifdef TOIT_FREERTOS
extern "C" {

#define mbedtls_aes_init esp_aes_init
#define mbedtls_aes_free esp_aes_free
#define mbedtls_aes_setkey_enc esp_aes_setkey
#define mbedtls_aes_setkey_dec esp_aes_setkey
#define mbedtls_aes_crypt_cbc esp_aes_crypt_cbc
#define mbedtls_aes_crypt_ecb esp_aes_crypt_ecb

}
#endif
