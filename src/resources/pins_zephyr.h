// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once
#include "../top.h"
#ifdef TOIT_ZEPHYR
#include <zephyr/device.h>
namespace toit {
// Pin numbers are 32 * port index + local pin. The ordered GPIO controllers
// and restricted pins are board data in the toit,platform devicetree node.
const device* zephyr_gpio_port(int num);
bool zephyr_pin_is_restricted(int num);
int zephyr_pin_claim(int num);
void zephyr_pin_release(int num);

// Transactional ownership, including the legacy encoding for borrowed Pin
// objects. A peripheral's member keeps its pins until native teardown finishes.
class ZephyrPins {
 public:
  ~ZephyrPins() { release(); }
  int add(int encoded, int* decoded) {
    bool owned = encoded >= 0;
    int64 num = encoded >= -1 ? encoded : -static_cast<int64>(encoded) - 2;
    if (num == -1) { *decoded = -1; return 0; }
    if (num > INT32_MAX || zephyr_gpio_port(num) == null) return -EINVAL;
    if (count_ == 8) return -EINVAL;
    for (int i = 0; i < count_; i++) if (pins_[i] == num) return -EINVAL;
    if (owned) {
      if (zephyr_pin_is_restricted(num)) return -EPERM;
      int result = zephyr_pin_claim(num);
      if (result) return result;
    }
    pins_[count_] = num;
    owned_[count_++] = owned;
    *decoded = num;
    return 0;
  }
  void release() {
    while (count_) { --count_; if (owned_[count_]) zephyr_pin_release(pins_[count_]); }
  }
 private:
  int pins_[8];
  bool owned_[8];
  int count_ = 0;
};
}  // namespace toit
#endif
