// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "../top.h"
#ifdef TOIT_RP2350
#include "event_rp2350.h"

namespace toit {
Rp2350EventDispatcher* Rp2350EventDispatcher::instance_ = null;

Rp2350EventDispatcher::Rp2350EventDispatcher()
    : EventSource("RP2350 dispatcher", 0)
    , Thread("RP2350 events")
    , wake_(xSemaphoreCreateBinary()) {
  ASSERT(instance_ == null);
  if (wake_ == null) FATAL("cannot allocate RP2350 event semaphore");
  instance_ = this;
}

void Rp2350EventDispatcher::start() {
  if (!spawn()) FATAL("cannot start RP2350 event task");
}

Rp2350EventDispatcher::~Rp2350EventDispatcher() {
  {
    Locker locker(mutex());
    for (int i = 0; i < SOURCE_COUNT; i++) ASSERT(sources_[i] == null);
    stop_ = true;
  }
  wake();
  join();
  instance_ = null;
  vSemaphoreDelete(wake_);
}

void Rp2350EventDispatcher::attach(Source id, Rp2350PeripheralEventSource* source) {
  Locker locker(mutex());
  ASSERT(sources_[id] == null);
  sources_[id] = source;
  wake();
}

void Rp2350EventDispatcher::detach(Source id, Rp2350PeripheralEventSource* source) {
  // Wait for any in-flight poll before the driver's destructor removes state.
  // Lock order is dispatcher -> peripheral; wake never takes either mutex.
  Locker locker(mutex());
  ASSERT(sources_[id] == source);
  sources_[id] = null;
}

void Rp2350EventDispatcher::wake() {
  xSemaphoreGive(wake_);
}

void Rp2350EventDispatcher::wake_from_isr() {
  BaseType_t higher_priority_task_woken = pdFALSE;
  xSemaphoreGiveFromISR(wake_, &higher_priority_task_woken);
  portYIELD_FROM_ISR(higher_priority_task_woken);
}

void Rp2350EventDispatcher::entry() {
  while (true) {
    bool polling = false;
    {
      Locker locker(mutex());
      if (stop_) return;
      for (int i = 0; i < SOURCE_COUNT; i++) {
        if (sources_[i] != null) polling |= sources_[i]->poll();
      }
    }
    // A wake arriving during poll remains in the semaphore, avoiding the
    // check-then-sleep race. Idle peripherals cause no periodic wakeups.
    xSemaphoreTake(wake_, polling ? 1 : portMAX_DELAY);
  }
}
}  // namespace toit
#endif
