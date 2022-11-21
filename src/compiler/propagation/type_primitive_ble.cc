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

TYPE_PRIMITIVE_ANY(init)
TYPE_PRIMITIVE_ANY(create_peripheral_manager)
TYPE_PRIMITIVE_ANY(create_central_manager)
TYPE_PRIMITIVE_ANY(close)
TYPE_PRIMITIVE_ANY(release_resource)
TYPE_PRIMITIVE_ANY(scan_start)
TYPE_PRIMITIVE_ANY(scan_next)
TYPE_PRIMITIVE_ANY(scan_stop)
TYPE_PRIMITIVE_ANY(connect)
TYPE_PRIMITIVE_ANY(disconnect)
TYPE_PRIMITIVE_ANY(discover_services)
TYPE_PRIMITIVE_ANY(discover_services_result)
TYPE_PRIMITIVE_ANY(discover_characteristics)
TYPE_PRIMITIVE_ANY(discover_characteristics_result)
TYPE_PRIMITIVE_ANY(discover_descriptors)
TYPE_PRIMITIVE_ANY(discover_descriptors_result)
TYPE_PRIMITIVE_ANY(request_read)
TYPE_PRIMITIVE_ANY(get_value)
TYPE_PRIMITIVE_ANY(write_value)
TYPE_PRIMITIVE_ANY(set_characteristic_notify)
TYPE_PRIMITIVE_ANY(advertise_start)
TYPE_PRIMITIVE_ANY(advertise_stop)
TYPE_PRIMITIVE_ANY(add_service)
TYPE_PRIMITIVE_ANY(add_characteristic)
TYPE_PRIMITIVE_ANY(add_descriptor)
TYPE_PRIMITIVE_ANY(deploy_service)
TYPE_PRIMITIVE_ANY(set_value)
TYPE_PRIMITIVE_ANY(get_subscribed_clients)
TYPE_PRIMITIVE_ANY(notify_characteristics_value)
TYPE_PRIMITIVE_ANY(get_att_mtu)
TYPE_PRIMITIVE_ANY(set_preferred_mtu)
TYPE_PRIMITIVE_ANY(get_error)
TYPE_PRIMITIVE_ANY(gc)

}  // namespace toit::compiler
}  // namespace toit
