// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
#include <zephyr/kernel.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/i2c.h>
#include <zephyr/drivers/pinctrl.h>
#include <zephyr/pm/device.h>
#include <zephyr/dt-bindings/pinctrl/nrf-pinctrl.h>
#include <stdio.h>

PINCTRL_DT_DEV_CONFIG_DECLARE(DT_NODELABEL(i2c2));
static pinctrl_soc_pin_t active_pins[2], sleep_pins[2];
static const struct pinctrl_state states[] = {
  {.pins = active_pins, .pin_cnt = 2, .id = PINCTRL_STATE_DEFAULT},
  {.pins = sleep_pins, .pin_cnt = 2, .id = PINCTRL_STATE_SLEEP},
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
#define CHECK(call) do { int rc = (call); if (rc) { \
  printf("I2C lifecycle FAIL: %s = %d at cycle %d\n", #call, rc, cycle); return 1; } } while (0)

int main(void) {
  const struct device* bus = DEVICE_DT_GET(DT_NODELABEL(i2c2));
  struct pinctrl_dev_config* config = PINCTRL_DT_DEV_CONFIG_GET(DT_NODELABEL(i2c2));
  int cycle = -1;
  CHECK(gpio_pin_configure(DEVICE_DT_GET(DT_NODELABEL(gpio1)), 1, GPIO_INPUT | GPIO_PULL_DOWN));
  uint8_t tx[257], rx[17];
  for (int i = 0; i < sizeof(tx); i++) tx[i] = (i * 73 + 23) & 255;
  for (cycle = 0; cycle < 64; cycle++) {
    bool alternate = cycle & 1;
    active_pins[0] = NRF_PSEL(TWIM_SDA, (alternate ? 0 : 1), (alternate ? 8 : 2));
    active_pins[1] = NRF_PSEL(TWIM_SCL, (alternate ? 0 : 1), (alternate ? 9 : 3));
    for (int i = 0; i < 2; i++) {
      sleep_pins[i] = active_pins[i] | BIT(NRF_LP_POS);
      active_pins[i] |= NRF_PULL_UP << NRF_PULL_POS;
    }
    CHECK(pinctrl_update_states(config, states, ARRAY_SIZE(states)));
    CHECK(cycle == 0 ? device_init(bus) : pm_device_action_run(bus, PM_DEVICE_ACTION_RESUME));
    CHECK(i2c_configure(bus, I2C_MODE_CONTROLLER | I2C_SPEED_SET(I2C_SPEED_STANDARD)));
    CHECK(request(alternate ? "I2C_OPEN 18 23 17" : "I2C_OPEN 21 22 17"));
    // Address-only probes must not clock a dummy payload byte.
    CHECK(i2c_write(bus, tx, 0, 0x42));
    int nack = i2c_write(bus, tx, 0, 0x43);
    if (nack != -EIO) { printf("I2C NACK FAIL: %d\n", nack); return 1; }
    // A combined transaction exercises repeated START and DMA in both directions.
    CHECK(i2c_write_read(bus, 0x42, tx, sizeof(tx), rx, sizeof(rx)));
    for (int i = 0; i < sizeof(rx); i++) {
      if (rx[i] != ((i * 73 + 7) & 255)) {
        printf("I2C data FAIL: cycle=%d byte=%d actual=%d\n", cycle, i, rx[i]);
        return 1;
      }
    }
    CHECK(request("I2C_CHECK 257"));
    CHECK(request("I2C_CLOSE"));
    CHECK(request(alternate ? "CONFIG 18 DOWN 0" : "CONFIG 21 DOWN 0"));
    CHECK(request(alternate ? "CONFIG 23 DOWN 0" : "CONFIG 22 DOWN 0"));
    CHECK(pm_device_action_run(bus, PM_DEVICE_ACTION_SUSPEND));
    CHECK(request(alternate ? "CHECK 18 0" : "CHECK 21 0"));
    CHECK(request(alternate ? "CHECK 23 0" : "CHECK 22 0"));
  }
  printf("NRF5340 I2C LIFECYCLE PASS: 64 remaps, repeated START and releases\n");
  return 0;
}
