// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "pins_zephyr.h"
#ifdef TOIT_ZEPHYR
#include "../os.h"
#include <zephyr/drivers/gpio.h>
#define TOIT_PLATFORM DT_COMPAT_GET_ANY_STATUS_OKAY(toit_platform)
#define PORT_DEVICE(node, prop, index) DEVICE_DT_GET(DT_PHANDLE_BY_IDX(node, prop, index)),
namespace toit {
static const device* const ports[] = {
  DT_FOREACH_PROP_ELEM(TOIT_PLATFORM, gpio_ports, PORT_DEVICE)
};
static const int restricted[] = DT_PROP(TOIT_PLATFORM, reserved_pins);
static uint32_t claimed[ARRAY_SIZE(ports)] = {};
const device* zephyr_gpio_port(int num) {
  if (num < 0 || num / 32 >= static_cast<int>(ARRAY_SIZE(ports))) return null;
  const device* port = ports[num / 32];
  if (!device_is_ready(port)) return null;
  auto config = static_cast<const gpio_driver_config*>(port->config);
  return config->port_pin_mask & BIT(num % 32) ? port : null;
}
bool zephyr_pin_is_restricted(int num) {
  for (int pin : restricted) if (pin == num) return true;
  return false;
}
int zephyr_pin_claim(int num) {
  if (zephyr_gpio_port(num) == null) return -EINVAL;
  Locker locker(OS::global_mutex());
  uint32_t mask = BIT(num % 32);
  if (claimed[num / 32] & mask) return -EBUSY;
  claimed[num / 32] |= mask;
  return 0;
}
void zephyr_pin_release(int num) {
  Locker locker(OS::global_mutex());
  // Reset before releasing ownership so a new owner cannot race cleanup.
  int result = gpio_pin_configure(ports[num / 32], num % 32, GPIO_DISCONNECTED);
  if (result != 0) FATAL("cannot release GPIO pin: %d", result);
  claimed[num / 32] &= ~BIT(num % 32);
}
}  // namespace toit
#endif
