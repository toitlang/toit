// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#include "zephyr.h"
#ifdef TOIT_ZEPHYR
namespace toit {
ZephyrEventSource* ZephyrEventSource::instance_ = null;

void ZephyrResource::notify(uint32_t flags) {
  unsigned key = irq_lock();
  pending_ |= flags;
  irq_unlock(key);
  static_cast<ZephyrEventSource*>(resource_group()->event_source())->wake();
}
uint32_t ZephyrResource::take_pending() {
  unsigned key = irq_lock();
  uint32_t result = pending_;
  pending_ = 0;
  irq_unlock(key);
  return result;
}
ZephyrEventSource::ZephyrEventSource() : EventSource("Zephyr"), Thread("Zephyr events") {
  ASSERT(instance_ == null);
  instance_ = this;
  k_sem_init(&wake_, 0, 1);
  if (!spawn()) FATAL("cannot start Zephyr event worker");
}
ZephyrEventSource::~ZephyrEventSource() {
  {
    Locker locker(mutex());
    stop_ = true;
  }
  wake();
  join();
  instance_ = null;
}
void ZephyrEventSource::entry() {
  for (;;) {
    k_sem_take(&wake_, K_FOREVER);
    Locker locker(mutex());
    if (stop_) return;
    for (auto resource : resources()) {
      auto zephyr_resource = static_cast<ZephyrResource*>(resource);
      uint32_t pending = zephyr_resource->take_pending();
      if (pending) dispatch(locker, resource, pending);
    }
  }
}
}  // namespace toit
#endif
