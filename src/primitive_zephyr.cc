// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "top.h"
#ifdef TOIT_ZEPHYR
#include "objects_inline.h"
#include "os.h"
#include "primitive.h"
#include "primitive_zephyr.h"
#include "process.h"
#include "resources/pins_zephyr.h"
#include <hal/nrf_clock.h>
#include <hal/nrf_gpiote.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/hwinfo.h>
#include <zephyr/pm/device.h>
#include <zephyr/sys/poweroff.h>
#include <zephyr/sys/reboot.h>

// Reset reporting uses Zephyr APIs. Sleep transitions currently implement
// nRF5340 System OFF/System ON behavior and must be adapted for another SoC.
BUILD_ASSERT(IS_ENABLED(CONFIG_SOC_NRF5340_CPUAPP));
namespace toit {
Object* zephyr_error(int error, Process* process) {
  ASSERT(error < 0);
  switch (error) {
    case -EINVAL: FAIL(INVALID_ARGUMENT);
    case -EBUSY: FAIL(ALREADY_IN_USE);
    case -EPERM: FAIL(PERMISSION_DENIED);
    case -ENOMEM: FAIL(MALLOC_FAILED);
    case -EMSGSIZE: FAIL(OUT_OF_RANGE);
    default: return Primitive::os_error(-error, process);
  }
}

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

MODULE_IMPLEMENTATION(zephyr, MODULE_ZEPHYR)

static const int MAX_SLEEP_MS = 24 * 60 * 60 * 1000;
static const int WAKE_PIN_COUNT = 64;
static const int WAKE_ENABLED = 8;
// Device-wide configuration, like ESP32 external wake and EC618 wake pads.
// Only primitives mutate it. Sleep reads it after every VM thread has stopped.
static uint8_t wake_configs[WAKE_PIN_COUNT];

static bool valid_wake_pin(int pin) {
  return pin >= 0 && pin < WAKE_PIN_COUNT && zephyr_gpio_port(pin) != null &&
      !zephyr_pin_is_restricted(pin);
}

PRIMITIVE(configure_wakeup_pin) {
  ARGS(int, pin, int, flags);
  if (!valid_wake_pin(pin)) FAIL(INVALID_ARGUMENT);
  if (flags != 0 && (flags < WAKE_ENABLED || flags > 15 || (flags & 6) == 6)) {
    FAIL(INVALID_ARGUMENT);
  }
  Locker locker(OS::global_mutex());
  wake_configs[pin] = flags;
  return process->null_object();
}

PRIMITIVE(validate_sleep) {
  ARGS(int, duration_ms);
  if (duration_ms < 1 || duration_ms > MAX_SLEEP_MS) FAIL(INVALID_ARGUMENT);
  return Smi::from(duration_ms);
}

static k_sem wake_signal;
static gpio_callback wake_callbacks[WAKE_PIN_COUNT / 32];

static void on_wake_pin(const device* port, gpio_callback*, gpio_port_pins_t pins) {
  // Level interrupts must be disabled before returning or an active input
  // keeps interrupting and can starve the thread that performs the reboot.
  for (int pin = 0; pin < 32; pin++) {
    if ((pins & BIT(pin)) == 0) continue;
    if (gpio_pin_interrupt_configure(port, pin, GPIO_INT_DISABLE) != 0) {
      sys_reboot(SYS_REBOOT_COLD);
    }
  }
  k_sem_give(&wake_signal);
}

void zephyr_enter_sleep(int64 request) {
  bool timed = request != INT64_MIN;
  if (timed && (request < 1 || request > MAX_SLEEP_MS)) {
    FATAL("invalid timed sleep request");
  }
  if (timed) {
    printf("[toit] System ON sleep for %lld ms\n", static_cast<long long>(request));
  } else {
    bool any = false;
    for (int pin = 0; pin < WAKE_PIN_COUNT; pin++) {
      if (wake_configs[pin] == 0) continue;
      any = true;
      printf("[toit] System OFF wake-pin=%d active=%d\n", pin, wake_configs[pin] & 1);
    }
    if (!any) printf("[toit] System OFF wake-pin=-1 active=0\n");
  }
  fflush(stdout);
  const device* console = DEVICE_DT_GET(DT_CHOSEN(zephyr_console));
  int result = pm_device_action_run(console, PM_DEVICE_ACTION_SUSPEND);
  if (result) FATAL("cannot suspend console: %d", result);

  if (timed) {
    // Nordic requires 64 MHz and low-power GPIO-event latency for low-current
    // System ON idle. VM peripheral resources have already been retired.
    nrf_clock_hfclk_div_set(NRF_CLOCK, NRF_CLOCK_HFCLK_DIV_2);
    SystemCoreClockUpdate();
    nrf_gpiote_latency_set(
        reinterpret_cast<NRF_GPIOTE_Type*>(DT_REG_ADDR(DT_NODELABEL(gpiote))),
        NRF_GPIOTE_LATENCY_LOWPOWER);
    k_sem_init(&wake_signal, 0, 1);
    for (int port_index = 0; port_index < WAKE_PIN_COUNT / 32; port_index++) {
      uint32_t mask = 0;
      const device* port = null;
      for (int bit = 0; bit < 32; bit++) {
        int pin = port_index * 32 + bit;
        if (wake_configs[pin] == 0) continue;
        mask |= BIT(bit);
        port = zephyr_gpio_port(pin);
      }
      if (mask == 0) continue;
      gpio_init_callback(&wake_callbacks[port_index], on_wake_pin, mask);
      result = gpio_add_callback(port, &wake_callbacks[port_index]);
      if (result) FATAL("cannot install sleep wake callback: %d", result);
    }
  } else {
    // Preserve an already-active sense condition until SYSTEMOFF is written.
    irq_lock();
  }

  for (int pin = 0; pin < WAKE_PIN_COUNT; pin++) {
    int flags = wake_configs[pin];
    if (flags == 0) continue;
    const device* port = zephyr_gpio_port(pin);
    gpio_flags_t mode = GPIO_INPUT;
    if (flags & 2) mode |= GPIO_PULL_UP;
    if (flags & 4) mode |= GPIO_PULL_DOWN;
    result = gpio_pin_configure(port, pin % 32, mode);
    if (!result) result = gpio_pin_interrupt_configure(port, pin % 32,
        flags & 1 ? GPIO_INT_LEVEL_HIGH : GPIO_INT_LEVEL_LOW);
    if (result) sys_reboot(SYS_REBOOT_COLD);
  }

  if (timed) {
    // An already-active pin can signal before the wait begins; the semaphore
    // preserves that wake. Otherwise the first pin or timeout ends the sleep.
    // The watchdog is neither stopped nor fed.
    k_sem_take(&wake_signal, K_MSEC(request));
    sys_reboot(SYS_REBOOT_COLD);
  }
  sys_poweroff();
}

PRIMITIVE(reset_reason) { return Smi::from(reset_reason); }
PRIMITIVE(supported_reset_reasons) { return Smi::from(supported_reset_reasons); }

}  // namespace toit
#endif
