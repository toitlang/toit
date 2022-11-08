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

// RAII helper class to just lock the mutex from a non-toit thread
class LightLocker {
 public:
  explicit LightLocker(Mutex *mutex): mutex_(mutex) {
    OS::lock(mutex_);
  }
  ~LightLocker() {
    OS::unlock(mutex_);
  }
 private:
  Mutex* mutex_;
};

class BLEResourceGroup;

class BLEEvent;

typedef DoubleLinkedList<BLEEvent> BLEEventList;

class HostBLEEventSource: public LazyEventSource, public Thread {
 public:
  HostBLEEventSource();
  ~HostBLEEventSource() override;

  static HostBLEEventSource* instance() { return instance_; }

  void on_event(BLEResource* resource, word data);

 protected:
  bool start() override;
  void stop() override;

  [[noreturn]] void entry() override;

 private:
  static HostBLEEventSource* instance_;
  ConditionVariable* event_queue_updated_;
  BLEEventList event_queue_;
};

class BLEEvent: public BLEEventList::Element {
 public:
  BLEEvent(BLEResource *resource, word event): resource_(resource), event_(event) {}
  BLEResource* resource() { return resource_; }
  word event() { return event_; }
 private:
  BLEResource* resource_;
  word event_;
};
} // Namespace toit.
