// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
#pragma once
#include "../top.h"
#ifdef TOIT_ZEPHYR
#include "../resource.h"
#include <zephyr/kernel.h>

namespace toit {

// Interrupts only accumulate flags and wake the worker. Resource lookup and
// dispatch happen under the event-source lock, so close cannot leave queued
// pointers referring to freed resources. Flags coalesce instead of overflowing
// a fixed-size queue.
class ZephyrResource : public Resource {
 public:
  explicit ZephyrResource(ResourceGroup* group) : Resource(group) {}
  void notify(uint32_t flags);
  uint32_t take_pending();
 private:
  uint32_t pending_ = 0;
};

class ZephyrEventSource : public EventSource, public Thread {
 public:
  static ZephyrEventSource* instance() { return instance_; }
  ZephyrEventSource();
  ~ZephyrEventSource();
  void wake() { k_sem_give(&wake_); }
 private:
  void entry() override;
  static ZephyrEventSource* instance_;
  struct k_sem wake_;
  bool stop_ = false;
};
}  // namespace toit
#endif
