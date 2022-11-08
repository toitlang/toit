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

HostBLEEventSource* HostBLEEventSource::instance_ = null;

HostBLEEventSource::HostBLEEventSource()
    : LazyEventSource("BLE Events"), Thread("BLE Events"),
      event_queue_updated_(OS::allocate_condition_variable(mutex())), event_queue_() {
  instance_ = this;
  spawn();
}

HostBLEEventSource::~HostBLEEventSource() {
  instance_ = null;
}

bool HostBLEEventSource::start() {
  return true;
}

void HostBLEEventSource::stop() {}

void HostBLEEventSource::on_event(BLEResource* resource, word data) {
  LightLocker locker(mutex());
  event_queue_.append(_new BLEEvent(resource, data));
  OS::signal(event_queue_updated_);
}

[[noreturn]] void HostBLEEventSource::entry() {
  Locker locker(mutex());

  while (true) {
    while (!event_queue_.is_empty()) {
      BLEEvent* event = event_queue_.remove_first();
      dispatch(locker, event->resource(), event->event());
    }
    OS::wait(event_queue_updated_);
  }
}

} // Namespace toit.
#endif
