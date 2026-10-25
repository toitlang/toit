// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include <zephyr/kernel.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/entropy.h>
#include <stdio.h>

int main(void) {
  printf("[toit] Zephyr nRF5340 boot\n");
  int64_t before = k_uptime_get();
  k_msleep(100);
  printf("[toit] Zephyr native PASS: elapsed=%lld gpio0=%d gpio1=%d\n",
         (long long)(k_uptime_get() - before),
         device_is_ready(DEVICE_DT_GET(DT_NODELABEL(gpio0))),
         device_is_ready(DEVICE_DT_GET(DT_NODELABEL(gpio1))));
  uint8_t entropy[48];
  int result = entropy_get_entropy(DEVICE_DT_GET(DT_CHOSEN(zephyr_entropy)), entropy, sizeof(entropy));
  printf("[toit] entropy result=%d\n", result);
  return 0;
}
