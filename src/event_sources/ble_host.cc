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

HostBleEventSource* HostBleEventSource::instance_ = null;

HostBleEventSource::HostBleEventSource()
    : LazyEventSource("BLE Events"), Thread("BLE Events"),
      event_queue_updated_(OS::allocate_condition_variable(mutex())), event_queue_() {
  instance_ = this;
  spawn();
}

HostBleEventSource::~HostBleEventSource() {
  instance_ = null;
}

bool HostBleEventSource::start() {
  return true;
}

void HostBleEventSource::stop() {}

void HostBleEventSource::on_event(BleResource* resource, word data) {
  LightLocker locker(mutex());
  event_queue_.append(_new BleEvent(resource, data));
  OS::signal(event_queue_updated_);
}

[[noreturn]] void HostBleEventSource::entry() {
  Locker locker(mutex());

  while (true) {
    while (!event_queue_.is_empty()) {
      BleEvent* event = event_queue_.remove_first();
      dispatch(locker, event->resource(), event->event());
    }
    OS::wait(event_queue_updated_);
  }
}

} // Namespace toit.
#endif
