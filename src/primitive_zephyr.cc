// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "top.h"
#ifdef TOIT_ZEPHYR
#include "objects_inline.h"
#include "primitive.h"
#include "primitive_zephyr.h"
#include "process.h"
#include "resources/pins_zephyr.h"
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/hwinfo.h>
#include <zephyr/drivers/watchdog.h>
#include <zephyr/pm/device.h>
#include <zephyr/sys/poweroff.h>
#include <zephyr/sys/reboot.h>

namespace toit {
static uint32_t reset_reason;
static uint32_t supported_reset_reasons;
void zephyr_capture_reset_reason() {
  if (hwinfo_get_reset_cause(&reset_reason) != 0 ||
      hwinfo_get_supported_reset_cause(&supported_reset_reasons) != 0 ||
      hwinfo_clear_reset_cause() != 0) {
    FATAL("cannot capture reset cause");
  }
  printf("[toit] reset cause=0x%lx supported=0x%lx\n",
         static_cast<unsigned long>(reset_reason),
         static_cast<unsigned long>(supported_reset_reasons));
}

#define TOIT_PLATFORM DT_COMPAT_GET_ANY_STATUS_OKAY(toit_platform)
static const device* const watchdog = DEVICE_DT_GET(DT_PHANDLE(TOIT_PLATFORM, watchdog_port));
static K_MUTEX_DEFINE(watchdog_mutex);
static int watchdog_channel = -1;
static bool watchdog_running = false;

static int watchdog_enable() {
  // Continue counting in ordinary sleep, but allow a debugger to halt the CPU.
  int result = wdt_setup(watchdog, WDT_OPT_PAUSE_HALTED_BY_DBG);
  if (!result) watchdog_running = true;
  return result;
}

static int watchdog_disable() {
  if (watchdog_channel < 0) return 0;
  // A failed setup can leave an allocated channel. Retrying setup before stop
  // lets the driver free that channel instead of leaking another on each retry.
  if (!watchdog_running) {
    int result = watchdog_enable();
    if (result) return result;
  }
  int result = wdt_disable(watchdog);
  if (!result) {
    watchdog_channel = -1;
    watchdog_running = false;
  }
  return result;
}

MODULE_IMPLEMENTATION(zephyr, MODULE_ZEPHYR)

static const int MAX_SLEEP_MS = 24 * 60 * 60 * 1000;
static bool valid_wake_config(int pin, int flags) {
  if (flags < 0 || flags > 7 || (flags & 6) == 6) return false;
  if (pin == -1) return (flags & 6) == 0;
  return pin >= 0 && pin < 64 && zephyr_gpio_port(pin) != null &&
      !zephyr_pin_is_restricted(pin);
}

PRIMITIVE(prepare_poweroff) {
  ARGS(int, pin, int, flags);
  if (!valid_wake_config(pin, flags)) FAIL(INVALID_ARGUMENT);
  // Carry the entire request in the scheduler exit value. There is no global
  // pending configuration for another process to overwrite before shutdown.
  int encoded = pin == -1 ? 0 : ((pin + 1) << 3) | flags;
  return Smi::from(-1 - encoded);
}

PRIMITIVE(validate_sleep) {
  ARGS(int, duration_ms);
  if (duration_ms < 1 || duration_ms > MAX_SLEEP_MS) FAIL(INVALID_ARGUMENT);
  return Smi::from(duration_ms);
}

void zephyr_enter_sleep(int64 request) {
  int pin = -1;
  int flags = 0;
  if (request > 0) {
    if (request > MAX_SLEEP_MS) FATAL("invalid timed sleep request");
    printf("[toit] System ON sleep for %lld ms\n", static_cast<long long>(request));
  } else {
    if (request < -520 || request == 0) FATAL("invalid power-off request");
    int encoded = static_cast<int>(-request - 1);
    pin = (encoded >> 3) - 1;
    flags = encoded & 7;
    if (!valid_wake_config(pin, flags)) FATAL("invalid wake GPIO configuration");
    printf("[toit] System OFF wake-pin=%d active=%d\n", pin, flags & 1);
  }
  fflush(stdout);
  const device* console = DEVICE_DT_GET(DT_CHOSEN(zephyr_console));
  int result = pm_device_action_run(console, PM_DEVICE_ACTION_SUSPEND);
  if (result) FATAL("cannot suspend console: %d", result);
  if (request > 0) {
    // The nRF5340 RTC cannot wake System OFF. Keep the Zephyr timebase alive
    // with the VM stopped, then reboot. Do not stop or feed the watchdog.
    k_sleep(K_MSEC(request));
    sys_reboot(SYS_REBOOT_COLD);
  }
  // Do not let an already-active GPIO run a level IRQ and consume the wake
  // condition before SYSTEMOFF is written. GPIO is armed only after teardown.
  irq_lock();
  if (pin >= 0) {
    const device* port = zephyr_gpio_port(pin);
    gpio_flags_t mode = GPIO_INPUT;
    if (flags & 2) mode |= GPIO_PULL_UP;
    if (flags & 4) mode |= GPIO_PULL_DOWN;
    result = gpio_pin_configure(port, pin % 32, mode);
    if (!result) result = gpio_pin_interrupt_configure(port, pin % 32,
        flags & 1 ? GPIO_INT_LEVEL_HIGH : GPIO_INT_LEVEL_LOW);
    if (result) sys_reboot(SYS_REBOOT_COLD);
  }
  sys_poweroff();
}

PRIMITIVE(reset_reason) { return Smi::from(reset_reason); }
PRIMITIVE(supported_reset_reasons) { return Smi::from(supported_reset_reasons); }

PRIMITIVE(watchdog_start) {
  ARGS(int, timeout_ms);
  // nRF's 32-bit LFCLK counter, expressed in whole milliseconds.
  if (timeout_ms < 1 || timeout_ms > 0x07cfffff) FAIL(INVALID_ARGUMENT);
  if (!device_is_ready(watchdog)) FAIL(HARDWARE_ERROR);
  k_mutex_lock(&watchdog_mutex, K_FOREVER);
  Defer unlock { [&] { k_mutex_unlock(&watchdog_mutex); } };
  int result = watchdog_disable();
  if (result) return Primitive::os_error(result, process);
  wdt_timeout_cfg config = {};
  config.window.max = timeout_ms;
  config.flags = WDT_FLAG_RESET_SOC;
  result = wdt_install_timeout(watchdog, &config);
  if (result < 0) return Primitive::os_error(result, process);
  watchdog_channel = result;
  result = watchdog_enable();
  if (result) return Primitive::os_error(result, process);
  return process->null_object();
}

PRIMITIVE(watchdog_feed) {
  k_mutex_lock(&watchdog_mutex, K_FOREVER);
  Defer unlock { [&] { k_mutex_unlock(&watchdog_mutex); } };
  if (watchdog_running) {
    int result = wdt_feed(watchdog, watchdog_channel);
    if (result) return Primitive::os_error(result, process);
  }
  return process->null_object();
}

PRIMITIVE(watchdog_stop) {
  k_mutex_lock(&watchdog_mutex, K_FOREVER);
  Defer unlock { [&] { k_mutex_unlock(&watchdog_mutex); } };
  int result = watchdog_disable();
  if (result) return Primitive::os_error(result, process);
  return process->null_object();
}
}  // namespace toit
#endif
