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

import system.services show ServiceProvider ServiceResource
import system.api.network show NetworkService

import ..shared.network_base

class NetworkServiceProvider extends NetworkServiceProviderBase:
  constructor:
    super "system/network/host" --major=0 --minor=1

  connect client/int -> List:
    resource := NetworkResource this client
    return [resource.serialize_for_rpc, NetworkService.PROXY_NONE]

class NetworkResource extends ServiceResource:
  constructor provider/ServiceProvider client/int:
    super provider client

  on_closed -> none:
    // Do nothing.
