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
  An object (opaque from the Toit side) for holding a cryptographic key.
*/
class CryptographicKey : public SimpleResource {
 public:
  TAG(CryptographicKey);
  CryptographicKey(SimpleResourceGroup* group, int length)
      : SimpleResource(group)
      , length_(length)
      , key_(null) {}
  virtual ~CryptographicKey();

  const uint8* key() const { return key_; }
  int length() const { return length_; }

  void set_key(const uint8* key) {
    key_ = key;
  }

  int length_;
  const uint8* key_;
};

/**
  GCM is a mode for crypto operations that supports AEAD (Authenticated
  encryption with associated data).  This is used for popular TLS symmetric
  (post-handshake) crypto operations like TLS_AES_128_GCM_SHA256.

  Associated data is not currently supported (data that is authenticated, but
  not encrypted).
*/
class GcmContext : public SimpleResource {
 public:
  TAG(GcmContext);
  // The cipher_id is one of:
  // MBEDTLS_CIPHER_ID_AES
  // MBEDTLS_CIPHER_ID_CHACHA20
  GcmContext(SimpleResourceGroup* group, const uint8* key, int key_length, mbedtls_cipher_id_t cipher_id, bool encrypt)
      : SimpleResource(group)
      , key_(key)
      , key_length_(key_length)
      , cipher_id_(cipher_id)
      , encrypt_(encrypt) {
    mbedtls_gcm_init(&context_);
  }

  virtual ~GcmContext();

  static const int NONCE_SIZE = 12;
  static const int BLOCK_SIZE = 16;
  static const int TAG_SIZE = 16;

  inline mbedtls_gcm_context* gcm_context() { return &context_; }
  inline const uint8* key() const { return key_; }
  inline int key_length() const { return key_length_; }
  inline mbedtls_cipher_id_t cipher_id() const { return cipher_id_; }
  inline bool is_encrypt() const { return encrypt_; }
  inline int remaining_length_in_current_message() const { return remaining_length_in_current_message_; }
  inline void set_remaining_length_in_current_message(int length) { remaining_length_in_current_message_ = length; }
  inline uint8* buffered_data() { return buffered_data_; }
  inline int buffered_bytes() const { return buffered_bytes_; }

 private:
  uint8 buffered_data_[BUFFER_SIZE];
  int buffered_bytes_ = 0;  // 0-15.
  const uint8* key_;
  int key_length_;
  uint8 iv_[IV_SIZE];
  mbedtls_cipher_id_t cipher_id_;
  bool encrypt_;
  mbedtls_gcm_context context_;
  int remaining_length_in_current_message_ = 0;
};

enum GcmAlgorithmType {
  ALGORITHM_AES_128_GCM_SHA256 = 0,
  ALGORITHM_CHACHA20_POLY1305  = 1,
  NUMBER_OF_ALGORITHM_TYPES    = 2
};

}
