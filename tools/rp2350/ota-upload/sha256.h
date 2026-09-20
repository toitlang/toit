// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.

#pragma once

#include <stddef.h>
#include <stdint.h>

class Sha256 {
 public:
  Sha256();

  void update(const uint8_t* data, size_t length);
  void finish(uint8_t digest[32]);

 private:
  void transform(const uint8_t block[64]);

  uint32_t state_[8];
  uint64_t byte_count_;
  uint8_t pending_[64];
  size_t pending_length_;
};
