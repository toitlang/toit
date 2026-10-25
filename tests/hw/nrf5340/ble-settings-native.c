// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
#include <errno.h>
#include <string.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/kernel.h>
#include <zephyr/settings/settings.h>
#include <zephyr/sys/crc.h>
#include <zephyr/sys/printk.h>

static bool found;
static bool name_found;
static char saved_name[CONFIG_BT_DEVICE_NAME_MAX + 1];
static struct k_thread observer;
K_THREAD_STACK_DEFINE(observer_stack, 1536);

static int name_value(const char *name, size_t length, settings_read_cb read,
                      void *read_arg, void *unused) {
  (void)unused;
  if (name && name[0]) return 0;
  if (!length || length >= sizeof(saved_name) || read(read_arg, saved_name, length) != length) {
    return -EINVAL;
  }
  saved_name[length] = 0;
  name_found = true;
  return 0;
}

static void observe(void *a, void *b, void *c) {
  (void)a; (void)b; (void)c;
  int64_t deadline = k_uptime_get() + 20000;
  while (!bt_is_ready() && k_uptime_get() < deadline) k_sleep(K_MSEC(1));
  // The matching Toit test never changes the GAP name. Seeing this value in
  // the live host therefore checks restoration, not a later application write.
  if (!bt_is_ready() || strcmp(bt_get_name(), saved_name) != 0) {
    printk("NRF5340 BT RESTORED NAME FAIL\n");
    return;
  }
  printk("NRF5340 BT RESTORED NAME PASS\n");
}

static int identity(const char *name, size_t length, settings_read_cb read,
                    void *read_arg, void *unused) {
  (void)unused;
  if (name && name[0]) return 0;
  bt_addr_le_t address;
  if (length != sizeof(address) || read(read_arg, &address, sizeof(address)) != sizeof(address)) {
    return -EINVAL;
  }
  if (address.type != BT_ADDR_LE_PUBLIC && address.type != BT_ADDR_LE_RANDOM) return -EINVAL;
  found = true;
  // This is the public identity address, not an IRK or any pairing key.
  printk("NRF5340 BT STORED ID crc=%08x\n", crc32_ieee((uint8_t *)&address, sizeof(address)));
  return 0;
}

int toit_zephyr_startup_test(void) {
  int err = settings_subsys_init();
  if (err) return err;
  // Direct inspection does not run Bluetooth handlers before bt_enable. The
  // adapter worker must still load and commit the Bluetooth subtree itself.
  err = settings_load_subtree_direct("bt/id", identity, NULL);
  if (!err && !found) printk("NRF5340 BT NO STORED ID\n");
  if (err) return err;
  err = settings_load_subtree_direct("bt/name", name_value, NULL);
  if (err) return err;
  if (!name_found || strcmp(saved_name, "Toit nRF5340 test") != 0) return -ENOENT;
  printk("NRF5340 BT STORED NAME PASS\n");
  k_thread_create(&observer, observer_stack, K_THREAD_STACK_SIZEOF(observer_stack),
                  observe, NULL, NULL, NULL, 10, 0, K_NO_WAIT);
  return 0;
}
