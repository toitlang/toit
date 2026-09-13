// Copyright (C) 2026 Toit contributors.
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

#ifdef TOIT_EC618

namespace toit {

// The PMU has six physical, input-only wake sources. Inputs 0..2 are module
// WAKEUP0, VBUS/WAKEUP1, and USIM_DET/WAKEUP2. Inputs 3..5 also have ordinary
// EC618 pad identities: PAD40..42 / GPIO20..22.
static const int kWakeupPadCount = 6;
static const int kFirstGpioWakeupPad = 40;
static const int kLastGpioWakeupPad = 42;
static const int kFirstGpioWakeupIndex = 3;

static inline int wakeup_index_for_pad(int pad) {
  if (pad < kFirstGpioWakeupPad || pad > kLastGpioWakeupPad) return -1;
  return kFirstGpioWakeupIndex + pad - kFirstGpioWakeupPad;
}

static inline bool is_valid_wakeup_index(int index) {
  return 0 <= index && index < kWakeupPadCount;
}

enum WakeupPadConfig {
  kWakeupEnabled = 1 << 0,
  kWakeupPositiveEdge = 1 << 1,
  kWakeupNegativeEdge = 1 << 2,
  kWakeupPullUp = 1 << 3,
  kWakeupPullDown = 1 << 4,
  // Inputs 0..2 also have platform functions. Leave them untouched until the
  // application explicitly configures or disables them.
  kWakeupManaged = 1 << 5,
};

extern "C" int toit_capture_boot_wakeup_src();
extern "C" int toit_wakeup_pad_config(int index);
extern "C" void toit_restore_wakeup_config(const uint8_t* configs);

}  // namespace toit

#endif  // TOIT_EC618
