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

import net
import net.modules.udp

import system.services show ServiceDefinition ServiceResource

import ..shared.network_base

class NetworkServiceDefinition extends NetworkServiceDefinitionBase:
  constructor:
    super "system/network/host" --major=0 --minor=1

  connect client/int -> List:
    resource := NetworkResource this client
    return [resource.serialize_for_rpc, 0]

class NetworkResource extends ServiceResource:
  constructor service/ServiceDefinition client/int:
    super service client

  on_closed -> none:
    // Do nothing.
