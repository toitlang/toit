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

import .flash.registry
import .containers
import .system_rpc_broker

import .api.containers

main:
  container_manager/ContainerManager := initialize
  boot container_manager
  // TODO(kasper): Should we reboot here after a little while?

initialize -> ContainerManager:
  flash_registry ::= FlashRegistry.scan
  rpc_broker := SystemRpcBroker
  container_manager := ContainerManager flash_registry rpc_broker
  rpc_broker.install container_manager
  ContainerApi rpc_broker container_manager  // Set up RPC-based APIs.
  return container_manager

boot container_manager/ContainerManager -> int:
  // TODO(kasper): Only start containers that should run on boot.
  container_manager.images.do: | image/ContainerImage |
    image.start
  return container_manager.wait_until_done
