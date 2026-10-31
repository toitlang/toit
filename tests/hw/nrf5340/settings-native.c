// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
#include <errno.h>
#include <string.h>
#include <zephyr/kernel.h>
#include <zephyr/settings/settings.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/reboot.h>

#define PREFIX "toit-nrf-qualification/"
#define CHECK(condition) do { \
  if (!(condition)) { printk("Settings qualification failed at line %d\n", __LINE__); return -EIO; } \
} while (0)

struct loaded_value {
  void *bytes;
  size_t capacity;
  ssize_t length;
};

static int load_value(const char *name, size_t length, settings_read_cb read,
                      void *read_arg, void *arg) {
  struct loaded_value *value = arg;
  if (name && name[0]) return 0;  // Only the requested key, not descendants.
  if (length > value->capacity) return -E2BIG;
  value->length = read(read_arg, value->bytes, length);
  return value->length == (ssize_t)length ? 0 : -EIO;
}

static ssize_t get(const char *key, void *bytes, size_t capacity) {
  struct loaded_value value = {bytes, capacity, -ENOENT};
  int err = settings_load_subtree_direct(key, load_value, &value);
  return err ? err : value.length;
}

static void pattern(uint8_t *bytes, size_t length, unsigned generation) {
  for (size_t i = 0; i < length; i++) bytes[i] = generation * 13 + i * 7;
}

int toit_zephyr_startup_test(void) {
  CHECK(settings_subsys_init() == 0);
  CHECK(settings_subsys_init() == 0);
  uint32_t phase = 0;
  ssize_t length = get(PREFIX "phase", &phase, sizeof(phase));
  CHECK(length == -ENOENT || length == sizeof(phase));
  CHECK(phase <= 3);
  printk("NRF5340 settings phase=%u\n", phase);
  uint8_t expected[512], actual[512];
  if (phase == 0) {
    pattern(expected, sizeof(expected), 0xa7);
    CHECK(settings_save_one(PREFIX "guard", expected, sizeof(expected)) == 0);
    // 128 KiB of value updates forces repeated collection in a 16 KiB area.
    for (unsigned generation = 0; generation < 256; generation++) {
      pattern(expected, sizeof(expected), generation);
      CHECK(settings_save_one(PREFIX "value", expected, sizeof(expected)) == 0);
      CHECK(get(PREFIX "value", actual, sizeof(actual)) == sizeof(actual));
      CHECK(memcmp(actual, expected, sizeof(actual)) == 0);
    }
    phase = 1;
    CHECK(settings_save_one(PREFIX "phase", &phase, sizeof(phase)) == 0);
    printk("NRF5340 settings rollover PASS; reset\n");
    sys_reboot(SYS_REBOOT_COLD);
  }
  pattern(expected, sizeof(expected), 0xa7);
  CHECK(get(PREFIX "guard", actual, sizeof(actual)) == sizeof(actual));
  CHECK(memcmp(actual, expected, sizeof(actual)) == 0);
  if (phase == 1) {
    pattern(expected, sizeof(expected), 255);
    CHECK(get(PREFIX "value", actual, sizeof(actual)) == sizeof(actual));
    CHECK(memcmp(actual, expected, sizeof(actual)) == 0);
    CHECK(settings_delete(PREFIX "value") == 0);
    CHECK(get(PREFIX "value", actual, sizeof(actual)) == -ENOENT);
    phase = 2;
    CHECK(settings_save_one(PREFIX "phase", &phase, sizeof(phase)) == 0);
    printk("NRF5340 settings reset persistence PASS; reset after deletion\n");
    sys_reboot(SYS_REBOOT_COLD);
  }
  CHECK(get(PREFIX "value", actual, sizeof(actual)) == -ENOENT);
  if (phase == 2) {
    phase = 3;
    CHECK(settings_save_one(PREFIX "phase", &phase, sizeof(phase)) == 0);
    printk("NRF5340 SETTINGS REFLASH READY: deletion persisted\n");
    // A second flash of this same image must preserve all settings bytes.
    while (true) k_sleep(K_FOREVER);
  }
  CHECK(phase == 3);
  CHECK(settings_delete(PREFIX "guard") == 0);
  CHECK(settings_delete(PREFIX "phase") == 0);
  CHECK(get(PREFIX "guard", actual, sizeof(actual)) == -ENOENT);
  CHECK(get(PREFIX "phase", actual, sizeof(actual)) == -ENOENT);
  printk("NRF5340 SETTINGS PASS: rollover, reset, deletion and firmware replacement\n");
  return 0;
}
