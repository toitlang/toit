// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "top.h"
#ifdef TOIT_ZEPHYR
#include "primitive_zephyr.h"
#include "objects_inline.h"
#include "primitive.h"
#include "process.h"
#include "watchdog.h"
#include <zephyr/drivers/watchdog.h>

namespace toit {
// The initial Zephyr backend uses Nordic's stoppable watchdog and LFCLK range.
BUILD_ASSERT(IS_ENABLED(CONFIG_SOC_NRF5340_CPUAPP));
#define TOIT_PLATFORM DT_COMPAT_GET_ANY_STATUS_OKAY(toit_platform)
static const device* const watchdog = DEVICE_DT_GET(DT_PHANDLE(TOIT_PLATFORM, watchdog_port));
static int watchdog_channel = -1;
static bool watchdog_running = false;

static int watchdog_enable() {
  // Continue counting in ordinary sleep, but allow a debugger to halt the CPU.
  int result = wdt_setup(watchdog, WDT_OPT_PAUSE_HALTED_BY_DBG);
  if (result == 0) watchdog_running = true;
  return result;
}

static int watchdog_disable() {
  if (watchdog_channel < 0) return 0;
  // A failed setup can leave an allocated channel. Retrying setup before stop
  // lets the driver free that channel instead of leaking another on each retry.
  if (!watchdog_running) {
    int result = watchdog_enable();
    if (result != 0) return result;
  }
  int result = wdt_disable(watchdog);
  if (result == 0) {
    watchdog_channel = -1;
    watchdog_running = false;
  }
  return result;
}

Object* platform_watchdog_start(Process* process, int timeout_ms) {
  // nRF's 32-bit LFCLK counter, expressed in whole milliseconds.
  if (timeout_ms < 1 || timeout_ms > 0x07cfffff) FAIL(INVALID_ARGUMENT);
  if (!device_is_ready(watchdog)) FAIL(HARDWARE_ERROR);
  Locker locker(OS::global_mutex());
  int result = watchdog_disable();
  if (result != 0) return zephyr_error(result, process);
  wdt_timeout_cfg config = {};
  config.window.max = timeout_ms;
  config.flags = WDT_FLAG_RESET_SOC;
  result = wdt_install_timeout(watchdog, &config);
  if (result < 0) return zephyr_error(result, process);
  watchdog_channel = result;
  result = watchdog_enable();
  if (result != 0) return zephyr_error(result, process);
  return process->null_object();
}

Object* platform_watchdog_feed(Process* process) {
  Locker locker(OS::global_mutex());
  if (watchdog_running) {
    int result = wdt_feed(watchdog, watchdog_channel);
    if (result != 0) return zephyr_error(result, process);
  }
  return process->null_object();
}

Object* platform_watchdog_stop(Process* process) {
  Locker locker(OS::global_mutex());
  int result = watchdog_disable();
  if (result != 0) return zephyr_error(result, process);
  return process->null_object();
}
}  // namespace toit
#endif
