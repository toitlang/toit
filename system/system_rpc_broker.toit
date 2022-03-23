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

import rpc.broker

import .containers

class SystemRpcBroker extends broker.RpcBroker:
  container_manager_/ContainerManager? := null

  install:
    unreachable

  install container_manager/ContainerManager:
    container_manager_ = container_manager
    super

  accept gid/int pid/int -> bool:
    container/Container? := container_manager_.lookup_container gid
    return container ? container.has_process pid : false

  // Register a descriptor-based procedure to handle a message.  These are
  // invoked by the RPC caller with a descriptor as the first argument.  This
  // descriptor is looked up on the process group and the resulting object is
  // passed to the handler.
  register_descriptor_procedure name/int action/Lambda -> none:
    register_procedure name:: | arguments gid pid |
      if not arguments is List or arguments.is_empty: throw "No handle provided"
      handle := arguments[0]
      if handle is not int: throw "Closed handle $handle"

      descriptor := container_manager_.lookup_descriptor gid pid handle
      if not descriptor: throw "Closed descriptor $handle"

      // Invoke the action and let that be the result of the procedure call.
      action.call descriptor arguments gid pid
