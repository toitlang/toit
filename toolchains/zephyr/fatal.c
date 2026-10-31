// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include <zephyr/fatal.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log_ctrl.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/reboot.h>

#ifdef CONFIG_TOIT_REBOOT_ON_FATAL_ERROR
void k_sys_fatal_error_handler(unsigned int reason, const struct arch_esf* esf) {
  ARG_UNUSED(esf);
  LOG_PANIC();
  printk("[toit] native fatal error=%u; resetting chip\n", reason);
  // Fatal errors may occur in an ISR or with corrupted kernel state. Do not
  // acquire VM locks, allocate, flush libc streams, or try to unwind resources.
  sys_reboot(SYS_REBOOT_COLD);
}
#endif
