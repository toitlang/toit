// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "update.h"
#include "recovery-stdio.h"

#include <stdio.h>
#include <string.h>
#include "hardware/flash.h"
#include "hardware/sync.h"
#include "hardware/structs/scb.h"
#include "hardware/structs/systick.h"
#include "hardware/structs/watchdog.h"
#include "hardware/watchdog.h"
#include "pico/stdio_usb.h"
#include "pico/stdlib.h"
#include "pico/unique_id.h"

const uint8_t* update_read(uint32_t offset) {
  return (const uint8_t*)(XIP_BASE + offset);
}

bool update_erase(uint32_t offset) {
  if (offset < UPDATE_INSTALLED || offset > 0x200000u - UPDATE_SECTOR ||
      (offset & (UPDATE_SECTOR - 1))) return false;
  watchdog_update();
  uint32_t irq = save_and_disable_interrupts();
  flash_range_erase(offset, UPDATE_SECTOR);
  restore_interrupts(irq);
  watchdog_update();
  for (unsigned i = 0; i < UPDATE_SECTOR; i++) {
    if (update_read(offset)[i] != 0xff) return false;
  }
  return true;
}

bool update_program(uint32_t offset, const uint8_t* page) {
  if (offset < UPDATE_INSTALLED || offset > 0x200000u - UPDATE_PAGE ||
      (offset & (UPDATE_PAGE - 1))) return false;
  watchdog_update();
  uint32_t irq = save_and_disable_interrupts();
  flash_range_program(offset, page, UPDATE_PAGE);
  restore_interrupts(irq);
  return memcmp(update_read(offset), page, UPDATE_PAGE) == 0;
}

static void reboot(void) {
  stdio_flush();
  watchdog_reboot(0, 0, 100);
  for (;;) tight_loop_contents();
}

static void launch(void) {
  const uint32_t* vectors = (const uint32_t*)(XIP_BASE + UPDATE_APP + 256);
  stdio_flush();
  stdio_usb_deinit();
  save_and_disable_interrupts();
  systick_hw->csr = 0;
  nvic_hw->icer = UINT32_MAX;
  nvic_hw->icpr = UINT32_MAX;
  scb_hw->icsr = M0PLUS_ICSR_PENDSTCLR_BITS | M0PLUS_ICSR_PENDSVCLR_BITS;
  scb_hw->vtor = (uintptr_t)vectors;
  watchdog_enable(8000, false);
  // No C code may run after replacing the stack. The application's CRT resets
  // peripherals and initializes its own data, vectors, clocks and USB stack.
  __asm volatile("msr msp, %0\n cpsie i\n bx %1" ::
      "r"(vectors[0]), "r"(vectors[1]) : "memory");
  __builtin_unreachable();
}

static bool read_exact(uint8_t* bytes, unsigned size) {
  uint64_t deadline = time_us_64() + 5000000;
  for (unsigned at = 0; at < size;) {
    int value = getchar_timeout_us(1000);
    if (value >= 0) bytes[at++] = value;
    if (time_us_64() >= deadline) return false;
    watchdog_update();
  }
  return true;
}

#ifndef TOIT_RP2040_RECOVERY_PIN
#define TOIT_RP2040_RECOVERY_PIN 1
#endif

int main(void) {
  bool stay = watchdog_enable_caused_reboot() ||
      watchdog_hw->scratch[0] == UPDATE_REQUEST;
  watchdog_hw->scratch[0] = 0;
  watchdog_enable(8000, false);
  // Recovery uses the rig's ESP32 TX -> UART RX wire, not BOOTSEL. Holding it
  // low during RUN reset catches even an application with broken USB/IRQs.
  gpio_init(TOIT_RP2040_RECOVERY_PIN);
  gpio_pull_up(TOIT_RP2040_RECOVERY_PIN);
  sleep_ms(20);
  if (!gpio_get(TOIT_RP2040_RECOVERY_PIN)) stay = true;
  gpio_disable_pulls(TOIT_RP2040_RECOVERY_PIN);
  stdio_init_all();
  if (!update_install()) stay = true;
  UpdateImage installed;
  bool have_app = update_installed(&installed);
  if (!have_app) stay = true;
#ifdef TOIT_RP2040_RECOVERY_TEST_APP
  // Run the real recovery protocol at the application address for hardware
  // validation. The installed loader remains untouched; never launch ourself.
  stay = true;
#endif
  char id[2 * PICO_UNIQUE_BOARD_ID_SIZE_BYTES + 1];
  pico_get_unique_board_id_string(id, sizeof(id));

  uint64_t boot_deadline = time_us_64() + 3000000;
  uint64_t heartbeat = 0;
  char line[128];
  unsigned length = 0;
  bool overflow = false;
  UpdateImage image = {0};
  uint32_t received = 0;
  bool receiving = false;
  uint64_t receive_deadline = 0;
  static uint8_t sector[UPDATE_SECTOR];
  for (;;) {
    watchdog_update();
    uint64_t now = time_us_64();
    if (receiving && (!stdio_usb_connected() || now >= receive_deadline)) {
      // An abandoned upload must not suppress recovery discovery forever.
      // Staged bytes have no committed descriptor, so discarding the session
      // leaves the installed application unchanged. Clear a partial command.
      receiving = false;
      received = 0;
      length = 0;
      overflow = false;
    }
    if (!stay && now >= boot_deadline) launch();
    if (now >= heartbeat && !receiving) {
#ifdef TOIT_RP2040_RECOVERY_TEST_APP
      recovery_reply("RP2040-RECOVERY-TEST id=%s\n", id);
#endif
      recovery_reply("RP2040-UPDATER 1 id=%s app=%lu size=%lu crc=%08lx\n", id,
          (unsigned long)(have_app ? installed.version : 0),
          (unsigned long)(have_app ? installed.size : 0),
          (unsigned long)(have_app ? installed.crc : 0));
      heartbeat = now + 1000000;
    }
    int value = getchar_timeout_us(1000);
    if (value < 0) continue;
    if (value == '\r') continue;
    if (value != '\n') {
      if (length < sizeof(line) - 1) line[length++] = value;
      else overflow = true;
      continue;
    }
    line[length] = 0;
    length = 0;
    if (overflow) {
      overflow = false;
      recovery_reply("ERR line\n");
      continue;
    }
    unsigned size, crc, version, offset;
    char extra;
    if (!strcmp(line, "hello")) {
      stay = true;
      recovery_reply("READY RP2040 1 %u %s\n", UPDATE_CAPACITY, id);
    } else if (sscanf(line, "begin %u %x %u %c", &size, &crc, &version, &extra) == 3) {
      stay = true;
      receiving = false;
      image = (UpdateImage){UPDATE_MAGIC, 1, size, crc, version, 0};
      image.header_crc = update_crc(&image, offsetof(UpdateImage, header_crc));
      if (!update_descriptor_valid(&image) || !update_begin()) {
        recovery_reply("ERR begin\n");
        continue;
      }
      received = 0;
      receiving = recovery_reply("OK begin\n");
      receive_deadline = time_us_64() + 10000000;
    } else if (sscanf(line, "block %u %u %x %c", &offset, &size, &crc, &extra) == 3) {
      if (!receiving || offset != received || offset >= image.size ||
          size == 0 || size > UPDATE_SECTOR || size > image.size - offset ||
          (size != UPDATE_SECTOR && size != image.size - offset)) {
        recovery_reply("ERR block\n");
        continue;
      }
      if (!recovery_reply("READY block\n")) {
        receiving = false;
        continue;
      }
      memset(sector, 0xff, sizeof(sector));
      if (!read_exact(sector, size) || update_crc(sector, size) != crc ||
          !update_stage(offset, sector)) {
        receiving = false;
        recovery_reply("ERR data\n");
        continue;
      }
      received += size;
      if (!recovery_reply("OK block %lu\n", (unsigned long)received)) receiving = false;
      receive_deadline = time_us_64() + 10000000;
    } else if (!strcmp(line, "commit")) {
      if (!receiving || received != image.size || !update_commit(&image)) {
        recovery_reply("ERR commit\n");
        continue;
      }
      // A committed descriptor is durable even if its acknowledgement fails.
      // Reboot still installs it; later discovery reports the committed image.
      recovery_reply("OK commit\n");
      reboot();
    } else if (!strcmp(line, "boot") && !receiving && have_app) {
#ifdef TOIT_RP2040_RECOVERY_TEST_APP
      recovery_reply("ERR boot unavailable in recovery test\n");
#else
      launch();
#endif
    } else {
      recovery_reply("ERR command\n");
    }
  }
}
