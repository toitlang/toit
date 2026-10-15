// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only. See LICENSE in the repository root.

#pragma once

namespace toit {
namespace ble_hci {

// The caller holds the callback lock for every operation, including target().
// Detach stops callbacks; only release after teardown admits another owner.
template <typename Resource>
class ControllerOwner {
 public:
  bool claim(Resource* resource) {
    if (resource == nullptr || owner_ != nullptr) return false;
    owner_ = target_ = resource;
    return true;
  }

  void detach(Resource* resource) {
    if (target_ == resource) target_ = nullptr;
  }

  bool release(Resource* resource) {
    if (resource == nullptr || owner_ != resource || target_ != nullptr) return false;
    owner_ = nullptr;
    return true;
  }

  Resource* target() const { return target_; }

 private:
  Resource* owner_ = nullptr;
  Resource* target_ = nullptr;
};

} // namespace ble_hci
} // namespace toit
