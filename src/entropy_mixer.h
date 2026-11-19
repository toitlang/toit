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

#define MBEDTLS_ALLOW_PRIVATE_ACCESS
#include <mbedtls/error.h>
#include "mbedtls_compat.h"
#if MBEDTLS_VERSION_MAJOR >= 4
#include <psa/crypto.h>
#endif

#include "top.h"
#include "os.h"
#include "utils.h"

namespace toit {

// A VM-global entropy mixer for random numbers.  Each process
// also has an entropy mixer if it starts TLS connections, but
// those are used by the TLS library and it does not do locking
// so we can't use those for a system-wide entropy mixer.
class EntropyMixer {
 public:
  EntropyMixer()
#ifndef TOIT_EC618
    : mutex_(OS::allocate_mutex(4, "Entropy mutex")) {
#if MBEDTLS_VERSION_MAJOR >= 4
    mbedtls_ctr_drbg_init(&context_);
#else
    mbedtls_entropy_init(&context_);
#endif
#else
    // On EC618, static constructors run before FreeRTOS is started,
    // so we can't allocate a mutex here. set_up is called during the
    // single-threaded VM startup, after the OS and mbedTLS threading setup.
    : mutex_(null) {
#endif
  }

  ~EntropyMixer() {
    if (mutex_) {
#if MBEDTLS_VERSION_MAJOR >= 4
      mbedtls_ctr_drbg_free(&context_);
#else
      mbedtls_entropy_free(&context_);
#endif
      OS::dispose(mutex_);
    }
  }

#ifdef TOIT_EC618
  void set_up() {
    ASSERT(mutex_ == null);
    mutex_ = OS::allocate_mutex(4, "Entropy mutex");
#if MBEDTLS_VERSION_MAJOR >= 4
    mbedtls_ctr_drbg_init(&context_);
#else
    mbedtls_entropy_init(&context_);
#endif
  }
#endif

  void add_entropy_byte(int datum) {
    const uint8 d = datum;
    add_entropy(&d, 1);
  }

  void add_entropy(const uint8* data, size_t size) {
    ASSERT(mutex_ != null);
    Locker locker(mutex_);
#if MBEDTLS_VERSION_MAJOR >= 4
    if (ensure_seeded()) mbedtls_ctr_drbg_update(&context_, data, size);
#else
    mbedtls_entropy_update_manual(&context_, data, size);
#endif
  }

  bool get_entropy(uint8* data, size_t size) {
    ASSERT(mutex_ != null);
    Locker locker(mutex_);
#if MBEDTLS_VERSION_MAJOR >= 4
    if (!ensure_seeded()) return false;
    int result = mbedtls_ctr_drbg_random(&context_, data, size);
#else
    int result = mbedtls_entropy_func(&context_, data, size);
#endif
    return result == 0;
  }

  static EntropyMixer* instance() { return &instance_; }

 private:
#if MBEDTLS_VERSION_MAJOR >= 4
  static int entropy_source(void*, unsigned char* output, size_t size) {
    return psa_generate_random(output, size) == PSA_SUCCESS
        ? 0 : MBEDTLS_ERR_CTR_DRBG_ENTROPY_SOURCE_FAILED;
  }

  // Seed lazily: the VM-global mixer is constructed before IDF's crypto setup.
  bool ensure_seeded() {
    if (seeded_) return true;
    if (psa_crypto_init() != PSA_SUCCESS) return false;
    seeded_ = mbedtls_ctr_drbg_seed(&context_, entropy_source, null, null, 0) == 0;
    return seeded_;
  }

  mbedtls_ctr_drbg_context context_;
  bool seeded_ = false;
#else
  mbedtls_entropy_context context_;
#endif
  Mutex* mutex_;
  static EntropyMixer instance_;
};

}
