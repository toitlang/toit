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
  explicit LightLocker(Mutex *mutex): _mutex(mutex) {
    OS::lock(_mutex);
  }
  ~LightLocker() {
    OS::unlock(_mutex);
  }
 private:
  Mutex* _mutex;
};

class BLEResourceGroup;

class BLEEvent;

typedef DoubleLinkedList<BLEEvent> BLEEventList;

class HostBLEEventSource: public LazyEventSource, public Thread {
 public:
  HostBLEEventSource();
  ~HostBLEEventSource() override;

  static HostBLEEventSource* instance() { return _instance; }

  void on_connection(BLEResource* resource, bool success);
  void on_event(BLEResource* resource, word data);

 protected:
  bool start() override;
  void stop() override;

  [[noreturn]] void entry() override;

  void on_register_resource(Locker &locker, Resource* r) override;

 private:
  static HostBLEEventSource* _instance;
  ConditionVariable* _event_queue_updated;
  BLEEventList _event_queue;
};

class BLEEvent: public BLEEventList::Element {
 public:
  BLEEvent(BLEResource *resource, word event): _resource(resource), _event(event) {}
  BLEResource* resource() { return _resource; }
  word event() { return _event; }
 private:
  BLEResource* _resource;
  word _event;
};
}