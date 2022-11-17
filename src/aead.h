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

#include "top.h"

#include "psa/crypto.h"

#include "resource.h"
#include "tags.h"

namespace toit {

/**
  AEAD (Authenticated encryption with associated data) are
  functions used for popular TLS symmetric (post-handshake)
  crypto operations like TLS_AES_128_GCM_SHA256.

  Associated data is not currently supported (data that is authenticated, but
  not encrypted).
*/
class AeadContext : public SimpleResource {
 public:
  TAG(AeadContext);
  // The algorithm is one of:
  // PSA_ALG_GCM
  // PSA_ALG_CHACHA20_POLY1305
  AeadContext(SimpleResourceGroup* group, int algorithm, const Blob* key, const Blob* nonce);
  virtual ~AeadContext();

  static constexpr uint8 BLOCK_SIZE = 16;

  psa_aead_context context_;
};

/*
  AES-CBC context class. 
  In addition to the base AES context,
  this cipher type also needs an initialization 
  vector.
*/
class AesCbcContext : public AesContext {
 public:
  TAG(AesCbcContext);
  AesCbcContext(SimpleResourceGroup* group, const Blob* key, const uint8* iv, bool encrypt);
  
  uint8 iv_[AES_BLOCK_SIZE];
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
