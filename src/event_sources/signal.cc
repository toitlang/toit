// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

#include "../top.h"

#if defined(TOIT_POSIX) || defined(TOIT_WINDOWS)

#include "signal.h"

namespace toit {

SignalEventSource* SignalEventSource::instance_ = null;

const SignalInfo* SignalEventSource::find(int number) {
  for (const SignalInfo* info = signals_; info->name != null; info++) {
    ASSERT(0 < info->number && info->number <= MAX_SIGNAL);
    if (info->number == number) return info;
  }
  return null;
}

int SignalEventSource::number(const char* name) const {
  for (const SignalInfo* info = signals_; info->name != null; info++) {
    if (strcmp(info->name, name) == 0) return info->number;
  }
  return 0;
}

void SignalEventSource::on_register_resource(Locker& locker, Resource* r) {
  auto resource = static_cast<SignalResource*>(r);
  ASSERT(!resource->installed_);
  resource->installed_ = true;
  for (int number = 1; number <= MAX_SIGNAL; number++) {
    if (!resource->is_watched(number)) continue;
    if (counts_[number]++ == 0) install(locker, number);
  }
}

void SignalEventSource::on_unregister_resource(Locker& locker, Resource* r) {
  auto resource = static_cast<SignalResource*>(r);
  // Unregistering twice is allowed and must not touch the counts again.
  if (!resource->installed_) return;
  resource->installed_ = false;
  for (int number = 1; number <= MAX_SIGNAL; number++) {
    if (!resource->is_watched(number)) continue;
    if (--counts_[number] == 0) restore(locker, number);
  }
}

void SignalEventSource::deliver(Locker& locker, uint32 signals) {
  for (auto r : resources()) {
    auto resource = static_cast<SignalResource*>(r);
    uint32 bits = resource->bits_for(signals);
    if (bits == 0) continue;
    dispatch(locker, resource, bits);
  }
}

}  // namespace toit

#endif  // defined(TOIT_POSIX) || defined(TOIT_WINDOWS)
