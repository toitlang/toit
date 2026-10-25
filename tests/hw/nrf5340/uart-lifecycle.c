// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/pinctrl.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/pm/device.h>
#include <zephyr/dt-bindings/pinctrl/nrf-pinctrl.h>
#include <stdio.h>

PINCTRL_DT_DEV_CONFIG_DECLARE(DT_NODELABEL(uart1));
static pinctrl_soc_pin_t active_pins[2];
static pinctrl_soc_pin_t sleep_pins[2];
static const struct pinctrl_state states[] = {
  { .pins = active_pins, .pin_cnt = 2, .id = PINCTRL_STATE_DEFAULT },
  { .pins = sleep_pins, .pin_cnt = 2, .id = PINCTRL_STATE_SLEEP },
};
static unsigned sequence;
static int request(const char* command) {
  const struct device* ack = DEVICE_DT_GET(DT_NODELABEL(gpio1));
  printf("GPIO REQUEST %u %s\n", ++sequence, command);
  fflush(stdout);
  int64_t deadline = k_uptime_get() + 5000;
  while (gpio_pin_get(ack, 1) != (sequence & 1)) {
    if (k_uptime_get() >= deadline) return -ETIMEDOUT;
    k_msleep(1);
  }
  return 0;
}
static int close_uart(const struct device* uart) {
  int result = pm_device_action_run(uart, PM_DEVICE_ACTION_SUSPEND);
  if (result) return result;
#ifdef PROBE_DEINIT
  return device_deinit(uart);
#else
  return 0;
#endif
}
static int open_uart(const struct device* uart) {
#ifdef PROBE_DEINIT
  return device_init(uart);
#else
  return pm_device_action_run(uart, PM_DEVICE_ACTION_RESUME);
#endif
}
#define CHECK(call) do { int rc = (call); if (rc) { \
  printf("UART lifecycle FAIL: %s = %d at cycle %d\n", #call, rc, cycle); return 1; } } while (0)

int main(void) {
  const struct device* uart = DEVICE_DT_GET(DT_NODELABEL(uart1));
  struct pinctrl_dev_config* config = PINCTRL_DT_DEV_CONFIG_GET(DT_NODELABEL(uart1));
  int cycle = -1;
  CHECK(gpio_pin_configure(DEVICE_DT_GET(DT_NODELABEL(gpio1)), 1, GPIO_INPUT | GPIO_PULL_DOWN));
  CHECK(request("CONFIG 32 DOWN 0"));
  CHECK(request("CONFIG 18 DOWN 0"));
  CHECK(close_uart(uart));
  for (cycle = 0; cycle < 64; cycle++) {
    bool alternate = cycle & 1;
    active_pins[0] = NRF_PSEL(UART_TX, (alternate ? 0 : 1), (alternate ? 8 : 4));
    active_pins[1] = NRF_PSEL(UART_RX, (alternate ? 0 : 1), (alternate ? 9 : 5)) |
                     (NRF_PULL_UP << NRF_PULL_POS);
    sleep_pins[0] = active_pins[0] | BIT(NRF_LP_POS);
    sleep_pins[1] = (active_pins[1] & ~(NRF_PULL_MSK << NRF_PULL_POS)) | BIT(NRF_LP_POS);
    CHECK(pinctrl_update_states(config, states, ARRAY_SIZE(states)));
    CHECK(open_uart(uart));
    uart_poll_out(uart, 0x55);
    uart_poll_out(uart, 0xaa);
    k_msleep(2);  // Allow the final stop bit to finish before observing idle TX.
    CHECK(request(alternate ? "CHECK 32 0" : "CHECK 32 1"));
    CHECK(request(alternate ? "CHECK 18 1" : "CHECK 18 0"));
    CHECK(close_uart(uart));
    CHECK(request("CHECK 32 0"));
    CHECK(request("CHECK 18 0"));
  }
  printf("NRF5340 UART LIFECYCLE PASS: 64 remaps and releases\n");
  return 0;
}
