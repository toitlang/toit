// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license that can be
// found in the LICENSE file.

#pragma once

#include <stdint.h>

namespace toit {

// Serializes ownership of the system-wide modem. The caller holds the global
// mutex. SetFunction has appSetCFUN's signature and returns zero on success.
// Keep this independent of VM resources so command failures can be exercised.
class CellularModemState {
 public:
  using SetFunction = int32_t (*)(uint8_t);
  struct ConnectResult {
    int32_t error;
    bool already_in_use;
  };

  int32_t initialize(SetFunction set_function) {
    if (initialized_) return 0;
    int32_t error = set_function(0);
    initialized_ = error == 0;
    return error;
  }

  ConnectResult activate(const void* owner, SetFunction set_function) {
    if (owner_ != nullptr) return {0, true};
    int32_t error = initialize(set_function);
    if (error != 0) return {error, false};
    error = set_function(1);
    if (error != 0) {
      // A timed-out request may still take effect. Try to shut it down now;
      // if that also fails, retry CFUN=0 before accepting another owner.
      // Report the original enable error rather than masking it with cleanup.
      initialized_ = set_function(0) == 0;
      return {error, false};
    }
    owner_ = owner;
    return {0, false};
  }

  int32_t deactivate(const void* owner, SetFunction set_function) {
    if (owner_ == nullptr || owner_ != owner) return 0;
    int32_t error = set_function(0);
    // The resource is going away even when the command failed. Never retain
    // its pointer or assume a clean modem state after that failure.
    owner_ = nullptr;
    initialized_ = error == 0;
    return error;
  }

 private:
  bool initialized_ = false;
  const void* owner_ = nullptr;
};

}  // namespace toit
