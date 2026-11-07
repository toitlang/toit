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
#include <mbedtls/entropy.h>
#include <mbedtls/ctr_drbg.h>

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
#if !defined(TOIT_EC618) && !defined(TOIT_PICO)
    : mutex_(OS::allocate_mutex(4, "Entropy mutex")) {
    mbedtls_entropy_init(&context_);
    mbedtls_ctr_drbg_init(&random_);
#else
    // On EC618 and Pico targets, static constructors run before FreeRTOS is started,
    // so we can't allocate a mutex here. set_up is called during the
    // single-threaded VM startup, after the OS and mbedTLS threading setup.
    : mutex_(null) {
#endif
  }

  ~EntropyMixer() {
    if (mutex_) {
      mbedtls_ctr_drbg_free(&random_);
      mbedtls_entropy_free(&context_);
      OS::dispose(mutex_);
    }
  }

#if defined(TOIT_EC618) || defined(TOIT_PICO)
  void set_up() {
    ASSERT(mutex_ == null);
    mutex_ = OS::allocate_mutex(4, "Entropy mutex");
    mbedtls_entropy_init(&context_);
    mbedtls_ctr_drbg_init(&random_);
  }
#endif

  void add_entropy_byte(int datum) {
    const uint8 d = datum;
    add_entropy(&d, 1);
  }

  void add_entropy(const uint8* data, size_t size) {
    ASSERT(mutex_ != null);
    Locker locker(mutex_);
    mbedtls_entropy_update_manual(&context_, data, size);
  }

  bool get_entropy(uint8* data, size_t size) {
    ASSERT(mutex_ != null);
    Locker locker(mutex_);
    int result = mbedtls_entropy_func(&context_, data, size);
    return result == 0;
  }

  // Cryptographic output, distinct from the bounded entropy-source callback.
  // Serialize both lazy seeding and generation: RSA workers and VM primitives
  // can use this instance concurrently. Never expose a platform PRNG directly.
  bool get_random(uint8* data, size_t size) {
    ASSERT(mutex_ != null);
    if (size == 0) return true;
    Locker locker(mutex_);
    if (!random_seeded_) {
      static const uint8 personalization[] = "Toit crypto";
      int result = mbedtls_ctr_drbg_seed(&random_, mbedtls_entropy_func, &context_,
                                       personalization, sizeof(personalization) - 1);
      if (result != 0) {
        mbedtls_ctr_drbg_free(&random_);
        mbedtls_ctr_drbg_init(&random_);
        return false;
      }
      random_seeded_ = true;
    }
    while (size != 0) {
      size_t count = Utils::min(size, static_cast<size_t>(MBEDTLS_CTR_DRBG_MAX_REQUEST));
      if (mbedtls_ctr_drbg_random(&random_, data, count) != 0) return false;
      data += count;
      size -= count;
    }
    return true;
  }

  static EntropyMixer* instance() { return &instance_; }

 private:
  mbedtls_entropy_context context_;
  mbedtls_ctr_drbg_context random_;
  bool random_seeded_ = false;
  Mutex* mutex_;
  static EntropyMixer instance_;
};

}
