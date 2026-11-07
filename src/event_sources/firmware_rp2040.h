// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once
#include "../top.h"
#ifdef TOIT_RP2040
#include "../resource.h"
#include "../os.h"
#include "FreeRTOS.h"
#include "semphr.h"

namespace toit {
// The system firmware service owns this single bounded worker. No VM heap
// pointers are retained; submission copies at most one sector into native RAM.
class Rp2040FirmwareWorker : public EventSource, public Thread {
 public:
  enum Operation { BEGIN, STAGE, COMMIT };
  enum Status { IDLE, PENDING, SUCCEEDED, FAILED };
  Rp2040FirmwareWorker();
  ~Rp2040FirmwareWorker() override;
  static Rp2040FirmwareWorker* instance() { return instance_; }
  bool submit(Operation operation, uint32 argument, const uint8* bytes);
  Status status();
 private:
  void entry() override;
  static Rp2040FirmwareWorker* instance_;
  SemaphoreHandle_t wake_;
  bool started_ = false;
  bool stop_ = false;
  Status status_ = IDLE;
  Operation operation_ = BEGIN;
  uint32 argument_ = 0;
  uint8 buffer_[4096];
};
}  // namespace toit
#endif
