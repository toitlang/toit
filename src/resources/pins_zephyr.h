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

// Transactional ownership. A peripheral keeps its pins until native teardown
// finishes. The internal -1 sentinel represents an omitted optional pin.
class ZephyrPins {
 public:
  ~ZephyrPins() { release(); }
  int add(int encoded, int* decoded) {
    int num = encoded;
    if (num == -1) { *decoded = -1; return 0; }
    if (num < 0 || zephyr_gpio_port(num) == null) return -EINVAL;
    if (count_ == 8) return -EINVAL;
    for (int i = 0; i < count_; i++) if (pins_[i] == num) return -EINVAL;
    if (zephyr_pin_is_restricted(num)) return -EPERM;
    int result = zephyr_pin_claim(num);
    if (result != 0) return result;
    pins_[count_++] = num;
    *decoded = num;
    return 0;
  }
  void release() {
    while (count_ != 0) zephyr_pin_release(pins_[--count_]);
  }
 private:
  int pins_[8];
  int count_ = 0;
};
}  // namespace toit
#endif
