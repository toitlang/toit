// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.
#include "../top.h"

#if  defined(TOIT_LINUX) || defined(TOIT_WINDOWS) || defined(TOIT_DARWIN)

#include "ble_host.h"
namespace toit {

HostBLEEventSource* HostBLEEventSource::_instance = null;

HostBLEEventSource::HostBLEEventSource()
    : LazyEventSource("BLE Events"), Thread("BLE Events"),
      _event_queue_updated(OS::allocate_condition_variable(mutex())), _event_queue() {
  _instance = this;
  spawn();
}

HostBLEEventSource::~HostBLEEventSource() {
  _instance = null;
}

bool HostBLEEventSource::start() {
  return true;
}

void HostBLEEventSource::stop() {
}

void HostBLEEventSource::on_event(BLEResource* resource, word data) {
  LightLocker locker(mutex());
  _event_queue.append(_new BLEEvent(resource, data));
  OS::signal(_event_queue_updated);
}

[[noreturn]] void HostBLEEventSource::entry() {
  Locker locker(mutex());

  while (true) {
    while (!_event_queue.is_empty()) {
      BLEEvent* event = _event_queue.remove_first();
      dispatch(locker, event->resource(), event->event());
    }
    OS::wait(_event_queue_updated);
  }
}

}
#endif