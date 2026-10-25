// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/hwinfo.h>
#include <zephyr/kernel.h>
#include <zephyr/pm/device.h>
#include <zephyr/sys/poweroff.h>
#include <zephyr/sys/printk.h>

static const struct device* gpio0 = DEVICE_DT_GET(DT_NODELABEL(gpio0));
static const struct device* gpio1 = DEVICE_DT_GET(DT_NODELABEL(gpio1));
static int sequence;

static void request(const char* command) {
  printk("GPIO REQUEST %d %s\n", ++sequence, command);
  int64_t deadline = k_uptime_get() + 5000;
  while (gpio_pin_get(gpio1, 1) != (sequence & 1)) {
    __ASSERT(k_uptime_get() < deadline, "Fixture timeout");
    k_sleep(K_MSEC(1));
  }
}

int main(void) {
  printk("NRF5340 NATIVE POWEROFF BOOT\n");
  uint32_t cause = 0;
  __ASSERT(hwinfo_get_reset_cause(&cause) == 0, "Reset cause unavailable");
  hwinfo_clear_reset_cause();
  gpio_pin_configure(gpio1, 4, GPIO_INPUT);
  gpio_pin_configure(gpio1, 5, GPIO_INPUT);
  gpio_pin_configure(gpio1, 1, GPIO_INPUT | GPIO_PULL_DOWN);
  int phase = gpio_pin_get(gpio1, 4) | (gpio_pin_get(gpio1, 5) << 1);
  printk("NATIVE POWEROFF phase=%d cause=0x%x\n", phase, cause);
  __ASSERT(phase <= 2, "Invalid phase");
  if (phase != 0) __ASSERT(cause & RESET_LOW_POWER_WAKE, "Missing GPIO wake cause");
  k_sleep(K_MSEC(100));
  request("CONFIG 18 DOWN 0");
  request("CHECK 18 0");
  if (phase == 2) {
    printk("NRF5340 NATIVE POWEROFF PASS\n");
    return 0;
  }
  // P1.00 is driven by fixture GPIO13. Test both active levels.
  bool high = phase == 0;
  request(high ? "CONFIG 13 OUT 0" : "CONFIG 13 OUT 1");
  __ASSERT(gpio_pin_configure(gpio1, 0, GPIO_INPUT) == 0, "Wake GPIO configuration failed");
  __ASSERT(gpio_pin_interrupt_configure(gpio1, 0,
      high ? GPIO_INT_LEVEL_HIGH : GPIO_INT_LEVEL_LOW) == 0, "Wake sense configuration failed");
  gpio_pin_configure(gpio0, 8, GPIO_OUTPUT_HIGH);
  request("WAIT 18 1");
  request(phase == 0 ? "CONFIG 32 OUT 1" : "CONFIG 32 OUT 0");
  request(phase == 0 ? "CONFIG 33 OUT 0" : "CONFIG 33 OUT 1");
  gpio_pin_configure(gpio0, 8, GPIO_DISCONNECTED);
  printk("NATIVE POWEROFF entering wake-high=%d\n", high);
  const struct device* console = DEVICE_DT_GET(DT_CHOSEN(zephyr_console));
  __ASSERT(pm_device_action_run(console, PM_DEVICE_ACTION_SUSPEND) == 0, "Console suspend failed");
  sys_poweroff();
}
