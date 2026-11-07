// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "../top.h"
#ifdef TOIT_RP2040
#include "firmware_rp2040.h"
#include "hardware/flash.h"
#include "hardware/sync.h"
#include "../../toolchains/rp2040/update.h"

// Runtime writes are restricted to staging and its descriptor. The installed
// application, registry and loader cannot be modified through this backend.
static bool writable(uint32 offset, uint32 size) {
  return (size <= UPDATE_SECTOR && offset >= UPDATE_PENDING &&
          offset <= UPDATE_PENDING + UPDATE_SECTOR - size) ||
      (size <= UPDATE_CAPACITY && offset >= UPDATE_STAGE &&
       offset <= UPDATE_STAGE + UPDATE_CAPACITY - size);
}
extern "C" const uint8_t* update_read(uint32_t offset) {
  return reinterpret_cast<const uint8_t*>(XIP_BASE + offset);
}
extern "C" bool update_erase(uint32_t offset) {
  if ((offset & (UPDATE_SECTOR - 1)) || !writable(offset, UPDATE_SECTOR)) return false;
  uint32 irq = save_and_disable_interrupts();
  flash_range_erase(offset, UPDATE_SECTOR);
  restore_interrupts(irq);
  for (unsigned i = 0; i < UPDATE_SECTOR; i++) {
    if (update_read(offset)[i] != 0xff) return false;
  }
  return true;
}
extern "C" bool update_program(uint32_t offset, const uint8_t* page) {
  if ((offset & (UPDATE_PAGE - 1)) || !writable(offset, UPDATE_PAGE)) return false;
  uint32 irq = save_and_disable_interrupts();
  flash_range_program(offset, page, UPDATE_PAGE);
  restore_interrupts(irq);
  return memcmp(update_read(offset), page, UPDATE_PAGE) == 0;
}

namespace toit {
Rp2040FirmwareWorker* Rp2040FirmwareWorker::instance_ = null;
Rp2040FirmwareWorker::Rp2040FirmwareWorker()
    : EventSource("RP2040 firmware", 1)
    , Thread("RP2040 firmware")
    , wake_(xSemaphoreCreateBinary()) {
  if (wake_ == null) FATAL("cannot allocate firmware semaphore");
  ASSERT(instance_ == null);
  instance_ = this;
}
Rp2040FirmwareWorker::~Rp2040FirmwareWorker() {
  {
    Locker locker(mutex());
    stop_ = true;
  }
  if (started_) {
    xSemaphoreGive(wake_);
    join();
  }
  vSemaphoreDelete(wake_);
  instance_ = null;
}
bool Rp2040FirmwareWorker::submit(Operation operation, uint32 argument, const uint8* bytes) {
  Locker locker(mutex());
  if (status_ == PENDING) return false;
  if (!started_) {
    if (!spawn(4 * KB)) return false;
    started_ = true;
  }
  if (bytes != null) memcpy(buffer_, bytes, sizeof(buffer_));
  operation_ = operation;
  argument_ = argument;
  status_ = PENDING;
  xSemaphoreGive(wake_);
  return true;
}
Rp2040FirmwareWorker::Status Rp2040FirmwareWorker::status() {
  Locker locker(mutex());
  return status_;
}
void Rp2040FirmwareWorker::entry() {
  while (true) {
    xSemaphoreTake(wake_, portMAX_DELAY);
    Operation operation;
    uint32 argument;
    {
      Locker locker(mutex());
      if (stop_) return;
      operation = operation_;
      argument = argument_;
    }
    bool success = false;
    if (operation == BEGIN) {
      success = update_begin();
    } else if (operation == STAGE) {
      success = update_stage(argument, buffer_);
    } else {
      UpdateImage previous;
      memcpy(&previous, update_read(UPDATE_INSTALLED), sizeof(previous));
      UpdateImage image = {UPDATE_MAGIC, 1, argument,
          update_crc(update_read(UPDATE_STAGE), argument),
          update_descriptor_valid(&previous) ? previous.version + 1 : 0, 0};
      image.header_crc = update_crc(&image, offsetof(UpdateImage, header_crc));
      success = update_commit(&image);
    }
    {
      Locker locker(mutex());
      status_ = success ? SUCCEEDED : FAILED;
    }
  }
}
}  // namespace toit
#endif
