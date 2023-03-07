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

#include <mbedtls/error.h>
#include <mbedtls/entropy.h>

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
    : mutex_(OS::allocate_mutex(4, "Entropy mutex")) {
    mbedtls_entropy_init(&context_);
  }

  ~EntropyMixer() {
    mbedtls_entropy_free(&context_);
    OS::dispose(mutex_);
  }

  void add_entropy_byte(int datum) {
    const uint8 d = datum;
    add_entropy(&d, 1);
  }

  void add_entropy(const uint8* data, size_t size) {
    Locker locker(mutex_);
    mbedtls_entropy_update_manual(&context_, data, size);
  }

  bool get_entropy(uint8* data, size_t size) {
    Locker locker(mutex_);
    int result = mbedtls_entropy_func(&context_, data, size);
    return result == 0;
  }

  static EntropyMixer* instance() { return &instance_; }

 private:
  mbedtls_entropy_context context_;
  Mutex* mutex_;
  static EntropyMixer instance_;
};

}
