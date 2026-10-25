// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
// Test-only cleanup. Never link this hook into a bond persistence test image.
#include <errno.h>
#include <stdio.h>
#include <zephyr/settings/settings.h>
#include <zephyr/sys/printk.h>

static char keys[CONFIG_BT_MAX_PAIRED][64];
static size_t count;

static int collect(const char *name, size_t length, settings_read_cb read,
                   void *read_arg, void *unused) {
  (void)length; (void)read; (void)read_arg; (void)unused;
  if (!name || !name[0]) return -EINVAL;
  if (count == CONFIG_BT_MAX_PAIRED) return -ENOSPC;
  int size = snprintf(keys[count], sizeof(keys[count]), "bt/keys/%s", name);
  if (size < 0 || size >= sizeof(keys[count])) return -ENAMETOOLONG;
  count++;
  return 0;
}

int toit_zephyr_startup_test(void) {
  int err = settings_subsys_init();
  if (err) return err;
  err = settings_load_subtree_direct("bt/keys", collect, NULL);
  if (err) return err;
  // Delete after traversal, preserving the other Bluetooth and Toit settings.
  for (size_t i = 0; i < count; i++) {
    err = settings_delete(keys[i]);
    if (err) return err;
  }
  printk("NRF5340 TEST BONDS CLEARED count=%u\n", (unsigned)count);
  return 0;
}
