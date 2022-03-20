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
import .stack_traces
import .system_rpc_broker

import .api.containers

main:
  print "Booting ..."
  container_manager/ContainerManager? := null
  time := Duration.of:
    container_manager = boot
  print "Booting ... done in $time"
  container_manager.wait_until_done

boot -> ContainerManager:
  install_stack_trace_handler
  flash_registry ::= FlashRegistry.scan

  // TODO(kasper): Fetch configuration.

  rpc_broker := SystemRpcBroker
  container_manager := ContainerManager flash_registry rpc_broker
  rpc_broker.install container_manager

  // Set up RPC-based APIs.
  ContainerApi rpc_broker container_manager

  // TODO(kasper): Only start containers that require running on boot.
  container_manager.images.do: | image/ContainerImage |
    image.start
  return container_manager