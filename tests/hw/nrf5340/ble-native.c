// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
#include <zephyr/kernel.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/hci.h>
#include <zephyr/bluetooth/crypto.h>
#include <zephyr/sys/byteorder.h>
#include <zephyr/sys/printk.h>
#include <string.h>
#include <errno.h>

static unsigned reports;
static void received(const bt_addr_le_t* addr, int8_t rssi, uint8_t type,
                     struct net_buf_simple* data) {
  ++reports;
  if (reports <= 3) {
    char address[BT_ADDR_LE_STR_LEN];
    bt_addr_le_to_str(addr, address, sizeof(address));
    printk("BLE scan address=%s rssi=%d type=%u bytes=%u\n", address, rssi, type, data->len);
  }
}

int main(void) {
  printk("NRF5340 BLE NATIVE BOOT\n");
  int err = bt_enable(NULL);
  __ASSERT(err == 0, "Bluetooth initialization failed: %d", err);
  bt_addr_le_t addresses[CONFIG_BT_ID_MAX];
  size_t count = ARRAY_SIZE(addresses);
  bt_id_get(addresses, &count);
  __ASSERT(count > 0, "No Bluetooth identity");
  char address[BT_ADDR_LE_STR_LEN];
  bt_addr_le_to_str(&addresses[0], address, sizeof(address));
  printk("BLE HCI IPC initialized identity=%s\n", address);
  // FIPS-197 AES-128 example, checked in both byte orders over real HCI.
  uint8_t key[16], plaintext[16], encrypted[16];
  const uint8_t expected[16] = {
    0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30,
    0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4, 0xc5, 0x5a,
  };
  for (int i = 0; i < 16; ++i) { key[i] = i; plaintext[i] = i * 17; }
  __ASSERT(bt_encrypt_be(key, plaintext, encrypted) == 0, "AES BE command failed");
  __ASSERT(memcmp(encrypted, expected, 16) == 0, "AES BE result mismatch");
  sys_mem_swap(key, 16);
  sys_mem_swap(plaintext, 16);
  __ASSERT(bt_encrypt_le(key, plaintext, encrypted) == 0, "AES LE command failed");
  sys_mem_swap(encrypted, 16);
  __ASSERT(memcmp(encrypted, expected, 16) == 0, "AES LE result mismatch");
  uint8_t random[48], zeros[48] = {0};
  __ASSERT(bt_rand(random, sizeof(random)) == 0, "HCI random failed");
  __ASSERT(memcmp(random, zeros, sizeof(random)) != 0, "HCI random returned zeros");
  __ASSERT(bt_rand(NULL, 1) == -EINVAL, "Invalid random argument accepted");
  __ASSERT(bt_encrypt_le(NULL, plaintext, encrypted) == -EINVAL, "Invalid AES argument accepted");
  printk("BLE HCI AES-128 LE/BE known answers and 48-byte randomness PASS\n");
  const struct bt_data ad[] = {
    BT_DATA_BYTES(BT_DATA_FLAGS, BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR),
    BT_DATA(BT_DATA_NAME_COMPLETE, CONFIG_BT_DEVICE_NAME, sizeof(CONFIG_BT_DEVICE_NAME) - 1),
  };
  for (int cycle = 0; cycle < 4; ++cycle) {
    err = bt_le_adv_start(BT_LE_ADV_NCONN_IDENTITY, ad, ARRAY_SIZE(ad), NULL, 0);
    __ASSERT(err == 0, "Advertising failed: %d", err);
    err = bt_le_scan_start(BT_LE_SCAN_PASSIVE, received);
    __ASSERT(err == 0, "Scanning failed: %d", err);
    k_sleep(K_SECONDS(2));
    __ASSERT(bt_le_scan_stop() == 0, "Scan stop failed");
    __ASSERT(bt_le_adv_stop() == 0, "Advertising stop failed");
    printk("BLE advertising/scanning cycle=%d reports=%u\n", cycle, reports);
  }
  __ASSERT(bt_disable() == 0, "Bluetooth shutdown failed");
  __ASSERT(bt_enable(NULL) == 0, "Bluetooth reopen failed");
  __ASSERT(bt_disable() == 0, "Bluetooth second shutdown failed");
  printk("NRF5340 BLE NATIVE PASS: HCI IPC, four advertising/scanning cycles and shutdown reports=%u\n", reports);
  return 0;
}
