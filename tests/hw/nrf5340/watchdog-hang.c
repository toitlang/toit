// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
#include <zephyr/kernel.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/hwinfo.h>
#include <zephyr/drivers/watchdog.h>
#include <stdio.h>

int main(void) {
  const struct device* gpio = DEVICE_DT_GET(DT_NODELABEL(gpio1));
  const struct device* watchdog = DEVICE_DT_GET(DT_NODELABEL(wdt0));
  printf("NRF5340 WATCHDOG PROBE BOOT\n");
  uint32_t reason;
  if (hwinfo_get_reset_cause(&reason) || hwinfo_clear_reset_cause() ||
      gpio_pin_configure(gpio, 0, GPIO_INPUT) ||
      gpio_pin_configure(gpio, 1, GPIO_INPUT | GPIO_PULL_DOWN)) return 1;
  k_msleep(100);
  if (gpio_pin_get(gpio, 0)) {
    if (!(reason & RESET_WATCHDOG)) {
      printf("WATCHDOG PROBE FAIL cause=%u\n", reason);
      return 1;
    }
    printf("NRF5340 WATCHDOG IRQ-OFF PASS cause=%u\n", reason);
    return 0;
  }
  printf("GPIO REQUEST 1 CONFIG 13 OUT 1\n");
  fflush(stdout);
  int64_t deadline = k_uptime_get() + 5000;
  while (gpio_pin_get(gpio, 1) != 1) {
    if (k_uptime_get() >= deadline) return 1;
    k_msleep(1);
  }
  struct wdt_timeout_cfg config = {
    .window = {.min = 0, .max = 500}, .flags = WDT_FLAG_RESET_SOC,
  };
  if (wdt_install_timeout(watchdog, &config) < 0 ||
      wdt_setup(watchdog, WDT_OPT_PAUSE_HALTED_BY_DBG)) return 1;
  printf("WATCHDOG IRQ-OFF ARMED timeout=500\n");
  fflush(stdout);
  irq_lock();
  for (;;) __asm__ volatile("nop");
}
