// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
#include <zephyr/kernel.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/spi.h>
#include <zephyr/drivers/pinctrl.h>
#include <zephyr/pm/device.h>
#include <zephyr/dt-bindings/pinctrl/nrf-pinctrl.h>
#include <stdio.h>

PINCTRL_DT_DEV_CONFIG_DECLARE(DT_NODELABEL(spi4));
static pinctrl_soc_pin_t active_pins[3], sleep_pins[3];
static const struct pinctrl_state states[] = {
  {.pins = active_pins, .pin_cnt = 3, .id = PINCTRL_STATE_DEFAULT},
  {.pins = sleep_pins, .pin_cnt = 3, .id = PINCTRL_STATE_SLEEP},
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
static K_SEM_DEFINE(finished, 0, 1);
static int transfer_result;
static void complete(const struct device* dev, int result, void* context) {
  ARG_UNUSED(dev); ARG_UNUSED(context);
  transfer_result = result;
  k_sem_give(&finished);
}
#define CHECK(call) do { int rc = (call); if (rc) { \
  printf("SPI lifecycle FAIL: %s = %d at cycle %d\n", #call, rc, cycle); return 1; } } while (0)
int main(void) {
  const struct device* bus = DEVICE_DT_GET(DT_NODELABEL(spi4));
  struct pinctrl_dev_config* pins = PINCTRL_DT_DEV_CONFIG_GET(DT_NODELABEL(spi4));
  const struct device* ports[] = {DEVICE_DT_GET(DT_NODELABEL(gpio0)), DEVICE_DT_GET(DT_NODELABEL(gpio1))};
  int cycle = -1;
  CHECK(gpio_pin_configure(ports[1], 1, GPIO_INPUT | GPIO_PULL_DOWN));
  uint8_t tx[32], rx[32];
  for (int i = 0; i < sizeof(tx); i++) tx[i] = (i * 73 + 23) & 255;
  for (cycle = 0; cycle < 64; cycle++) {
    bool alternate = cycle & 1;
    int mode = (cycle / 2) % 4;
    int numbers[] = {alternate ? 36 : 8, alternate ? 37 : 9, alternate ? 34 : 10};
    int functions[] = {NRF_FUN_SPIM_SCK, NRF_FUN_SPIM_MOSI, NRF_FUN_SPIM_MISO};
    int cs = alternate ? 35 : 11;
    for (int i = 0; i < 3; i++) {
      active_pins[i] = (functions[i] << NRF_FUN_POS) | numbers[i];
      sleep_pins[i] = active_pins[i] | BIT(NRF_LP_POS);
    }
    CHECK(pinctrl_update_states(pins, states, ARRAY_SIZE(states)));
    CHECK(cycle == 0 ? device_init(bus) : pm_device_action_run(bus, PM_DEVICE_ACTION_RESUME));
    CHECK(gpio_pin_configure(ports[cs / 32], cs % 32, GPIO_OUTPUT_INACTIVE | GPIO_ACTIVE_LOW));
    char command[100];
    snprintf(command, sizeof(command), "SPI_ARM %d %d %d %d %d 32 BOTH 0",
             alternate ? 32 : 18, alternate ? 33 : 23, alternate ? 21 : 19, alternate ? 22 : 4, mode);
    CHECK(request(command));
    struct spi_config config = {
      .frequency = 1000000,
      .operation = SPI_WORD_SET(8) | SPI_LOCK_ON | ((mode & 1) ? SPI_MODE_CPHA : 0) | ((mode & 2) ? SPI_MODE_CPOL : 0),
      .cs = {.gpio = {.port = ports[cs / 32], .pin = cs % 32, .dt_flags = GPIO_ACTIVE_LOW}, .delay = 1, .cs_is_gpio = true},
    };
    struct spi_buf tx_buffer = {.buf = tx, .len = sizeof(tx)}, rx_buffer = {.buf = rx, .len = sizeof(rx)};
    struct spi_buf_set tx_buffers = {.buffers = &tx_buffer, .count = 1}, rx_buffers = {.buffers = &rx_buffer, .count = 1};
    CHECK(spi_transceive_cb(bus, &config, &tx_buffers, &rx_buffers, complete, NULL));
    CHECK(k_sem_take(&finished, K_SECONDS(1)));
    CHECK(transfer_result);
    CHECK(spi_release(bus, &config));
    CHECK(request("SPI_CHECK"));
    for (int i = 0; i < sizeof(rx); i++) {
      if (rx[i] != ((i * 73 + 7) & 255)) {
        printf("SPI data FAIL: cycle=%d byte=%d actual=%d\n", cycle, i, rx[i]); return 1;
      }
    }
    CHECK(pm_device_action_run(bus, PM_DEVICE_ACTION_SUSPEND));
    CHECK(gpio_pin_configure(ports[cs / 32], cs % 32, GPIO_DISCONNECTED));
    CHECK(request(alternate ? "CONFIG 32 DOWN 0" : "CONFIG 18 DOWN 0"));
    CHECK(request(alternate ? "CONFIG 22 DOWN 0" : "CONFIG 4 DOWN 0"));
    CHECK(request(alternate ? "CHECK 32 0" : "CHECK 18 0"));
    CHECK(request(alternate ? "CHECK 22 0" : "CHECK 4 0"));
  }
  printf("NRF5340 SPI LIFECYCLE PASS: 64 remaps, modes 0..3 and releases\n");
  return 0;
}
