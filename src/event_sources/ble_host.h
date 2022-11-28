// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#pragma once

#include "../resource.h"
#include "ble.h"

namespace toit {

// RAII helper class to just lock the mutex from a non-Toit thread.
class LightLocker {
 public:
  explicit LightLocker(Mutex* mutex) : mutex_(mutex) {
    OS::lock(mutex_);
  }
  ~LightLocker() {
    OS::unlock(mutex_);
  }
 private:
  Mutex* mutex_;
};

class BleResourceGroup;

class BleEvent;

typedef DoubleLinkedList<BleEvent> BleEventList;

class HostBleEventSource: public LazyEventSource, public Thread {
 public:
  HostBleEventSource();
  ~HostBleEventSource() override;

  static HostBleEventSource* instance() { return instance_; }

  void on_event(BleResource* resource, word data);

 protected:
  bool start() override;
  void stop() override;

  [[noreturn]] void entry() override;

 private:
  static HostBleEventSource* instance_;
  ConditionVariable* event_queue_updated_;
  BleEventList event_queue_;
};

class BleEvent: public BleEventList::Element {
 public:
  BleEvent(BleResource *resource, word event): resource_(resource), event_(event) {}
  BleResource* resource() { return resource_; }
  word event() { return event_; }
 private:
  BleResource* resource_;
  word event_;
};
} // Namespace toit.
