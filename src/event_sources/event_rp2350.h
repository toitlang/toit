// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once
#include "../top.h"
#ifdef TOIT_RP2350
#include "../os.h"
#include "../resource.h"
#include "FreeRTOS.h"
#include "semphr.h"

namespace toit {

class Rp2350PeripheralEventSource;

// One task handles every peripheral. The semaphore is only a wake token;
// drivers retain pending events in bounded atomic state, so coalesced wakeups
// cannot lose events or overflow an interrupt queue.
class Rp2350EventDispatcher : public EventSource, public Thread {
 public:
  enum Source { GPIO, UART, I2C, STDIO, SPI, SOURCE_COUNT };
  static Rp2350EventDispatcher* instance() { return instance_; }
  Rp2350EventDispatcher();
  ~Rp2350EventDispatcher() override;

  void start();
  void attach(Source id, Rp2350PeripheralEventSource* source);
  void detach(Source id, Rp2350PeripheralEventSource* source);
  void wake();
  void wake_from_isr();

 private:
  void entry() override;
  static Rp2350EventDispatcher* instance_;
  SemaphoreHandle_t wake_;
  Rp2350PeripheralEventSource* sources_[SOURCE_COUNT] = {};
  bool stop_ = false;
};

class Rp2350PeripheralEventSource : public EventSource {
 public:
  explicit Rp2350PeripheralEventSource(const char* name) : EventSource(name, 1) {}
  // Runs on the shared task. Returns whether a 1 ms hardware poll is needed.
  // Each implementation holds its own EventSource mutex while dispatching.
  virtual bool poll() = 0;
};

}  // namespace toit
#endif
