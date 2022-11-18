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
  AeadContext(SimpleResourceGroup* group, psa_key_id_t key_id, psa_algorithm_t algorithm, bool encrypt) {
      : key_id_(key_id)
      , algorithm_(algorithm),
      , encrypt_(encrypt),
      , operation_(PSA_AEAD_OPERATION_INIT) {
    if (encrypt) {
      psa_aead_encrypt_setup(&operation_, key_id, algorithm);
    } else {
      psa_aead_decrypt_setup(&operation_, key_id, algorithm);
    }
  }

  virtual ~AeadContext();

  static constexpr uint8 BLOCK_SIZE = 16;

  psa_aead_operation_t* psa_operation() { return &operation_; }
  psa_key_id_t psa_key_id() const { return key_id_; }
  psa_algorithm_t psa_algorithm() const { return algorithm_; }
  bool is_encrypt() const { return encrypt_; }

 private:
  psa_key_id_t key_id_;
  psa_algorithm_t algorithm_;
  bool encrypt_;
  psa_aead_operation_t operation_;
};

}
#endif
