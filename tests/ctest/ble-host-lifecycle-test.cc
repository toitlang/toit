// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

#include "../../src/top.h"
#include "../../src/event_sources/ble_host.h"
#include "../../src/os.h"

// Linux and Windows do not normally load this event source, but can exercise
// the same worker lifecycle that VM teardown uses on macOS, without a radio.
int main() {
  using namespace toit;
  OS::set_up();
  for (int iteration = 0; iteration < 256; iteration++) {
    auto source = _new HostBleEventSource();
    if (source == null) FATAL("event source allocation failed");
    if (HostBleEventSource::instance() != source) FATAL("missing event source");
    delete source;
    if (HostBleEventSource::instance() != null) FATAL("retained event source");
  }
  OS::tear_down();
  return 0;
}
