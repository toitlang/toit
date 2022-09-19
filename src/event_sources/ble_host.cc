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
  : LazyEventSource("BLE Events")
  , Thread("BLE Events")
  , _event_queue_updated(OS::allocate_condition_variable(mutex()))
  , _event_queue(){
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

void HostBLEEventSource::on_register_resource(Locker &locker, Resource* r) {
//  auto ble_resource = reinterpret_cast<BLEResource*>(r);
//  if (ble_resource->kind() == BLEResource::ADAPTER) {
//    auto simple_ble_adapter_resource = reinterpret_cast<SimpleBLEAdapterResource*>(ble_resource);
//    Adapter* adapter = simple_ble_adapter_resource->adapter();
//
//    adapter->set_callback_on_scan_found([=](const Peripheral& peripheral) {
//      simple_ble_adapter_resource->add_peripheral(new Peripheral(peripheral));
//      on_event(simple_ble_adapter_resource, SIMPLEBLE_SCAN_FOUND);
//    });
//
//    adapter->set_callback_on_scan_stop([=] {
//      on_event(simple_ble_adapter_resource, SIMPLEBLE_SCAN_STOP);
//    });
//  } else if (ble_resource->kind() == BLEResource::GAP) {
//    // Simulate a started event, to get GAP resource unlocked
//    // TODO: ???
//    dispatch(locker, r, SIMPLEBLE_INIT);
//  }
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
      dispatch(locker,event->resource(), event->event());
    }
    OS::wait(_event_queue_updated);
  }

}

void HostBLEEventSource::on_connection(BLEResource* resource, bool success) {
  //on_event(resource, success?SIMPLEBLE_CONNECTED_TO_REMOTE:SIMPLEBLE_FAILED_CONNECT_TO_REMOTE);
}

//void SimpleBLEAdapterResource::add_peripheral(Peripheral* peripheral) {
//  //_discovered_peripherals.append(_new DiscoveredPeripheral(peripheral));
//}
//
//Peripheral* SimpleBLEAdapterResource::next_peripheral() {
////  if (_discovered_peripherals.is_empty()) return null;
////  DiscoveredPeripheral* discovered_peripheral = _discovered_peripherals.remove_first();
////  Peripheral* peripheral = discovered_peripheral->peripheral();
////  delete discovered_peripheral;
////  return peripheral;
//  return null;
//}
//
}

#endif