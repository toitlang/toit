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

#include "mbedtls/gcm.h"

#include "resource.h"
#include "tags.h"

namespace toit {

/**
  GCM is a mode for crypto operations that supports AEAD (Authenticated
  encryption with associated data).  This is used for popular TLS symmetric
  (post-handshake) crypto operations like TLS_AES_128_GCM_SHA256.
*/
class GcmContext : public SimpleResource {
 public:
  TAG(GcmContext);
  // The cipher_id must currently be MBEDTLS_CIPHER_ID_AES.
  GcmContext(SimpleResourceGroup* group, mbedtls_cipher_id_t cipher_id, bool encrypt)
      : SimpleResource(group)
      , cipher_id_(cipher_id)
      , encrypt_(encrypt) {
    mbedtls_gcm_init(&context_);
  }

  virtual ~GcmContext();

  static const int NONCE_SIZE = 12;
  static const int BLOCK_SIZE = 16;
  static const int TAG_SIZE = 16;

  inline mbedtls_gcm_context* gcm_context() { return &context_; }
  inline mbedtls_cipher_id_t cipher_id() const { return cipher_id_; }
  inline bool is_encrypt() const { return encrypt_; }
  inline bool currently_generating_message() const { return currently_generating_message_; }
  inline void set_currently_generating_message() { currently_generating_message_ = true; }
  inline void increment_length(int by) { length_ += by; }
  inline uint8* buffered_data() { return buffered_data_; }
  inline int buffered_bytes() const { return length_ & (BLOCK_SIZE - 1); }

 private:
  uint8 buffered_data_[BLOCK_SIZE];
  int buffered_bytes_ = 0;  // 0-15.
  bool currently_generating_message_ = false;
  uint64_t length_ = 0;
  mbedtls_cipher_id_t cipher_id_;
  bool encrypt_;
  mbedtls_gcm_context context_;
};

enum GcmAlgorithmType {
  ALGORITHM_AES_GCM_SHA256 = 0,
  NUMBER_OF_ALGORITHM_TYPES    = 1
};

class MbedTLSResourceGroup;

// From resources/tls.cc.
extern Object* tls_error(MbedTLSResourceGroup* group, Process* process, int err);

}
