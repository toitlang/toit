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

import uuid
import system.containers

import .firmware
import .wifi

import ...boot
import ...initialize
import ...containers

// TODO(kasper): It feels annoying to have to put this here. Maybe we
// can have some sort of reasonable default in the ContainerManager?
class SystemImage extends ContainerImage:
  id ::= containers.current

  constructor manager/ContainerManager:
    super manager

  spawn container/Container arguments/any -> int:
    // This container is already running as the system process.
    return Process.current.id

  stop_all -> none:
    unreachable  // Not implemented yet.

  delete -> none:
    unreachable  // Not implemented yet.

main:
  container_manager ::= initialize_system [
      FirmwareServiceDefinition,
      WifiServiceDefinition
  ]
  container_manager.register_system_image
      SystemImage container_manager

  error ::= boot container_manager
  if error == 0: return

  // We encountered an error, so in order to recover, we restart the
  // device by going into deep sleep for the short amount of time as
  // decided by the underlying platform.
  __deep_sleep__ 0
