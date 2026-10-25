// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
#include <stdlib.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/hwinfo.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/__assert.h>
#include <zephyr/sys/printk.h>

static const struct device* gpio0 = DEVICE_DT_GET(DT_NODELABEL(gpio0));
static const struct device* gpio1 = DEVICE_DT_GET(DT_NODELABEL(gpio1));
static int sequence;
static int phase;

static void request(const char* command) {
  printk("GPIO REQUEST %d %s\n", ++sequence, command);
  int64_t deadline = k_uptime_get() + 5000;
  while (gpio_pin_get(gpio1, 1) != (sequence & 1)) {
    __ASSERT(k_uptime_get() < deadline, "Fixture acknowledgement timed out");
    k_sleep(K_MSEC(1));
  }
}

static void cpu_fault(void) {
  // A real UsageFault, rather than a call to the fatal policy handler.
  __asm__ volatile("udf #0");
  CODE_UNREACHABLE;
}

static void timer_fault(struct k_timer* timer) {
  ARG_UNUSED(timer);
  __ASSERT(k_is_in_isr(), "Expected interrupt context");
  printk("NATIVE FAULT interrupt-context phase=%d\n", phase);
  if (phase == 4) k_panic();
  cpu_fault();
}
K_TIMER_DEFINE(fault_timer, timer_fault, NULL);

int main(void) {
  printk("NRF5340 NATIVE FAULT BOOT\n");
  gpio_pin_configure(gpio1, 0, GPIO_INPUT);
  gpio_pin_configure(gpio1, 4, GPIO_INPUT);
  gpio_pin_configure(gpio1, 5, GPIO_INPUT);
  gpio_pin_configure(gpio1, 1, GPIO_INPUT | GPIO_PULL_DOWN);
  phase = gpio_pin_get(gpio1, 0) | (gpio_pin_get(gpio1, 4) << 1) |
          (gpio_pin_get(gpio1, 5) << 2);
  uint32_t cause = 0;
  __ASSERT(hwinfo_get_reset_cause(&cause) == 0, "Reset cause unavailable");
  hwinfo_clear_reset_cause();
  printk("NATIVE FAULT phase=%d cause=0x%x\n", phase, cause);
  __ASSERT(phase <= 6, "Invalid test phase");
  if (phase != 0) __ASSERT(cause & RESET_SOFTWARE, "Missing software-reset cause");
  k_sleep(K_MSEC(100));
  request("CONFIG 18 DOWN 0");
  request("CHECK 18 0");
  if (phase == 6) {
    printk("NRF5340 NATIVE FAULT PASS\n");
    return 0;
  }
  gpio_pin_configure(gpio0, 8, GPIO_OUTPUT_HIGH);
  request("WAIT 18 1");
  const int pins[] = {13, 32, 33};
  for (int bit = 0; bit < 3; bit++) {
    char command[32];
    snprintk(command, sizeof(command), "CONFIG %d OUT %d", pins[bit], ((phase + 1) >> bit) & 1);
    request(command);
  }
  printk("NATIVE FAULT injecting phase=%d\n", phase);
  switch (phase) {
    case 0: k_panic(); break;
    case 1: abort(); break;
    case 2: cpu_fault(); break;
    case 3: __ASSERT(false, "Expected test assertion"); break;
    case 4:
    case 5:
      k_timer_start(&fault_timer, K_MSEC(10), K_NO_WAIT);
      k_sleep(K_FOREVER);
      break;
  }
  __ASSERT(false, "Fault returned");
  return 1;
}
