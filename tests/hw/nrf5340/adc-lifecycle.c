// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
#include <zephyr/kernel.h>
#include <zephyr/drivers/adc.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/dt-bindings/adc/nrf-saadc.h>
#include <stdio.h>
#include <stdlib.h>

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
  printf("ADC lifecycle FAIL: %s = %d at cycle %d\n", #call, rc, cycle); return 1; } } while (0)

int main(void) {
  const struct device* adc = DEVICE_DT_GET(DT_NODELABEL(adc));
  const struct device* gpio = DEVICE_DT_GET(DT_NODELABEL(gpio0));
  int cycle = -1;
  CHECK(gpio_pin_configure(DEVICE_DT_GET(DT_NODELABEL(gpio1)), 1, GPIO_INPUT | GPIO_PULL_DOWN));
  CHECK(gpio_pin_configure(gpio, 4, GPIO_DISCONNECTED));
  CHECK(gpio_pin_configure(gpio, 5, GPIO_DISCONNECTED));
  int16_t buffer[64];
  struct adc_sequence_options options = {0};
  struct adc_sequence samples = {
    .options = &options, .channels = BIT(0), .buffer = buffer,
    .buffer_size = sizeof(buffer), .resolution = 12,
  };
  struct adc_channel_cfg config = {
    .gain = ADC_GAIN_1_6, .reference = ADC_REF_INTERNAL,
    .acquisition_time = ADC_ACQ_TIME(ADC_ACQ_TIME_MICROSECONDS, 40),
    .channel_id = 0,
  };
  uint32_t longest_us = 0;
  for (cycle = 0; cycle < 64; cycle++) {
    int first = (cycle % 7) * 500;
    char command[48];
    snprintf(command, sizeof(command), "ADC_DAC %d %d", first, 3000 - first);
    CHECK(request(command));
    k_msleep(5);
    for (int input = 0; input < 2; input++) {
      config.input_positive = input == 0 ? NRF_SAADC_AIN0 : NRF_SAADC_AIN1;
      CHECK(adc_channel_setup(adc, &config));
      struct adc_sequence calibration = samples;
      calibration.options = NULL;
      calibration.calibrate = true;
      CHECK(adc_read(adc, &calibration));
      const int counts[] = {1, 2, 17, 64};
      for (int n = 0; n < ARRAY_SIZE(counts); n++) {
        int count = counts[n];
        options.extra_samplings = count - 1;
        samples.buffer_size = count * sizeof(buffer[0]);
        uint32_t started = k_cycle_get_32();
        CHECK(adc_read(adc, &samples));
        uint32_t elapsed = k_cyc_to_us_floor32(k_cycle_get_32() - started);
        if (elapsed > longest_us) longest_us = elapsed;
        int total = 0;
        for (int i = 0; i < count; i++) total += buffer[i];
        int mv = total * 3600 / (count * 4096);
        int expected = input == 0 ? first : 3000 - first;
        printf("ADC cycle=%d input=%d count=%d expected=%d mV measured=%d mV elapsed=%u us\n",
               cycle, input, count, expected, mv, elapsed);
        if (abs(mv - expected) > 200) return 1;
      }
    }
  }
  // Bring both DACs low; the host returns the fixture to GPIO inputs afterward.
  CHECK(request("ADC_DAC 0 0"));
  printf("NRF5340 ADC LIFECYCLE PASS: 128 calibrations and 512 reads; longest=%u us\n", longest_us);
  return 0;
}
