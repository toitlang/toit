// Copyright (C) 2022 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#include "type_primitive.h"

namespace toit {
namespace compiler {

MODULE_TYPES(ble, MODULE_BLE)

TYPE_PRIMITIVE_BYTE_ARRAY(init)
TYPE_PRIMITIVE_BYTE_ARRAY(create_adapter)
TYPE_PRIMITIVE_BYTE_ARRAY(create_peripheral_manager)
TYPE_PRIMITIVE_BYTE_ARRAY(create_central_manager)
TYPE_PRIMITIVE_NULL(close)
TYPE_PRIMITIVE_NULL(release_resource)
TYPE_PRIMITIVE_NULL(scan_start)

TYPE_PRIMITIVE(scan_next) {
  result.add_array(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE_NULL(scan_stop)
TYPE_PRIMITIVE_BYTE_ARRAY(connect)
TYPE_PRIMITIVE_NULL(disconnect)
TYPE_PRIMITIVE_NULL(discover_services)
TYPE_PRIMITIVE_ARRAY(discover_services_result)
TYPE_PRIMITIVE_NULL(discover_characteristics)
TYPE_PRIMITIVE_ARRAY(discover_characteristics_result)
TYPE_PRIMITIVE_NULL(discover_descriptors)
TYPE_PRIMITIVE_ARRAY(discover_descriptors_result)
TYPE_PRIMITIVE_NULL(request_read)

TYPE_PRIMITIVE(get_value) {
  result.add_byte_array(program);
  result.add_null(program);
  failure.add_string(program);
}

TYPE_PRIMITIVE_SMI(write_value)
TYPE_PRIMITIVE_SMI(handle)
TYPE_PRIMITIVE_NULL(set_characteristic_notify)

TYPE_PRIMITIVE(advertise_start) {
  failure.add_string(program);
}

TYPE_PRIMITIVE_NULL(advertise_start_raw)
TYPE_PRIMITIVE_NULL(advertise_stop)
TYPE_PRIMITIVE_BYTE_ARRAY(add_service)
TYPE_PRIMITIVE_NULL(reserve_services)
TYPE_PRIMITIVE_NULL(start_gatt_server)
TYPE_PRIMITIVE_BYTE_ARRAY(add_characteristic)
TYPE_PRIMITIVE_BYTE_ARRAY(add_descriptor)
TYPE_PRIMITIVE_NULL(deploy_service)
TYPE_PRIMITIVE_NULL(set_value)
TYPE_PRIMITIVE_ARRAY(get_subscribed_clients)
TYPE_PRIMITIVE_NULL(notify_characteristics_value)
TYPE_PRIMITIVE_SMI(get_att_mtu)
TYPE_PRIMITIVE_NULL(set_preferred_mtu)

TYPE_PRIMITIVE(get_error) {
  failure.add_string(program);
}

TYPE_PRIMITIVE_NULL(clear_error)
TYPE_PRIMITIVE_ARRAY(get_bonded_peers)
TYPE_PRIMITIVE_NULL(toit_callback_init)
TYPE_PRIMITIVE_NULL(toit_callback_deinit)
TYPE_PRIMITIVE_NULL(toit_callback_reply)
TYPE_PRIMITIVE_NULL(set_gap_device_name)

}  // namespace toit::compiler
}  // namespace toit
