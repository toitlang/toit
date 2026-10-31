// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once
#include <zephyr/kernel.h>

namespace toit {
// Shared by VM entry points and Bluetooth callbacks. RX is not a Toit Thread
// and must never acquire OS::Mutex or call the VM scheduler directly.
extern struct k_mutex ble_zephyr_callback_mutex;
class CallbackLock {
 public:
  CallbackLock() { k_mutex_lock(&ble_zephyr_callback_mutex, K_FOREVER); }
  ~CallbackLock() { k_mutex_unlock(&ble_zephyr_callback_mutex); }
};
}  // namespace toit
