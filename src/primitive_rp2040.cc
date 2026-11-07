// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "top.h"
#ifdef TOIT_RP2040
#include "objects_inline.h"
#include "primitive.h"
#include "process.h"
#include "watchdog.h"
#include "hardware/watchdog.h"
#include "pico/unique_id.h"
#include "event_sources/firmware_rp2040.h"
#include "../toolchains/rp2040/update.h"

extern "C" bool toit_rp2040_recovery_requested();

namespace toit {
MODULE_IMPLEMENTATION(rp2040, MODULE_RP2040)

// The runtime watchdog catches native hangs and is fed by the boot process.
// An application watchdog takes exclusive ownership of the hardware timer:
// system feeds must never extend an application's deadline.
static bool app_watchdog_armed = false;

PRIMITIVE(unique_id) {
  ByteArray* result = process->allocate_byte_array(PICO_UNIQUE_BOARD_ID_SIZE_BYTES);
  if (result == null) FAIL(ALLOCATION_FAILED);
  pico_unique_board_id_t id;
  // The SDK reads the external flash identity before main and caches it in RAM.
  pico_get_unique_board_id(&id);
  ByteArray::Bytes bytes(result);
  memcpy(bytes.address(), id.id, sizeof(id.id));
  return result;
}

PRIMITIVE(system_watchdog_feed) {
  PRIVILEGED;
  if (!app_watchdog_armed) watchdog_update();
  return process->null_object();
}

PRIMITIVE(recovery_requested) {
  PRIVILEGED;
  return BOOL(toit_rp2040_recovery_requested());
}

PRIMITIVE(firmware_submit) {
  PRIVILEGED;
  ARGS(int, operation, int, argument, Blob, bytes);
  if (operation < 0 || operation > Rp2040FirmwareWorker::COMMIT) FAIL(INVALID_ARGUMENT);
  if (operation == Rp2040FirmwareWorker::STAGE) {
    if (argument < 0 || argument >= UPDATE_CAPACITY || (argument & (UPDATE_SECTOR - 1)) ||
        bytes.length() != UPDATE_SECTOR) FAIL(INVALID_ARGUMENT);
  } else {
    if (bytes.length() != 0) FAIL(INVALID_ARGUMENT);
    if (operation == Rp2040FirmwareWorker::COMMIT &&
        (argument < 264 || argument > UPDATE_CAPACITY)) FAIL(INVALID_ARGUMENT);
  }
  if (!Rp2040FirmwareWorker::instance()->submit(
      static_cast<Rp2040FirmwareWorker::Operation>(operation), argument,
      operation == Rp2040FirmwareWorker::STAGE ? bytes.address() : null)) FAIL(QUOTA_EXCEEDED);
  return process->null_object();
}

PRIMITIVE(firmware_status) {
  PRIVILEGED;
  return Smi::from(Rp2040FirmwareWorker::instance()->status());
}

Object* platform_watchdog_start(Process* process, int timeout_ms) {
  if (timeout_ms < 1000 || timeout_ms > 8000) FAIL(INVALID_ARGUMENT);
  watchdog_enable(timeout_ms, false);
  app_watchdog_armed = true;
  return process->null_object();
}

Object* platform_watchdog_feed(Process* process) {
  if (app_watchdog_armed) watchdog_update();
  return process->null_object();
}

Object* platform_watchdog_stop(Process* process) {
  if (app_watchdog_armed) watchdog_enable(8000, false);
  app_watchdog_armed = false;
  return process->null_object();
}
}  // namespace toit
#endif
