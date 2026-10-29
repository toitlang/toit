// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
// The external controller supplies AES and randomness. Zephyr 4.4 exposes the
// HCI commands but no longer supplies these wrappers without its PSA backend.
#include <errno.h>
#include <string.h>
#include <zephyr/bluetooth/crypto.h>
#include <zephyr/bluetooth/hci.h>
#include <zephyr/sys/byteorder.h>

int bt_rand(void* buffer, size_t length) {
  if (buffer == NULL || length == 0) return -EINVAL;
  return bt_hci_le_rand(buffer, length);
}

int bt_encrypt_le(const uint8_t key[16], const uint8_t plaintext[16], uint8_t result[16]) {
  if (key == NULL || plaintext == NULL || result == NULL) return -EINVAL;
  struct net_buf* command = bt_hci_cmd_alloc(K_FOREVER);
  if (command == NULL) return -ENOBUFS;
  struct bt_hci_cp_le_encrypt* parameters = net_buf_add(command, sizeof(*parameters));
  memcpy(parameters->key, key, 16);
  memcpy(parameters->plaintext, plaintext, 16);
  struct net_buf* response = NULL;
  int err = bt_hci_cmd_send_sync(BT_HCI_OP_LE_ENCRYPT, command, &response);
  if (err != 0) return err;
  if (response->len != sizeof(struct bt_hci_rp_le_encrypt)) {
    err = -EIO;
  } else {
    const struct bt_hci_rp_le_encrypt* data = (const void*)response->data;
    memcpy(result, data->enc_data, 16);
  }
  net_buf_unref(response);
  return err;
}

int bt_encrypt_be(const uint8_t key[16], const uint8_t plaintext[16], uint8_t result[16]) {
  if (key == NULL || plaintext == NULL || result == NULL) return -EINVAL;
  uint8_t reversed_key[16], reversed_plaintext[16];
  sys_memcpy_swap(reversed_key, key, 16);
  sys_memcpy_swap(reversed_plaintext, plaintext, 16);
  int err = bt_encrypt_le(reversed_key, reversed_plaintext, result);
  if (err == 0) sys_mem_swap(result, 16);
  return err;
}
