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

import .firmware
import .wifi

import ...boot
import ...initialize
import ...containers

// TODO(kasper): It feels annoying to have to put this here. Maybe we
// can have some sort of reasonable default in the ContainerManager?
class SystemImage extends ContainerImage:
  id ::= uuid.NIL
  constructor manager/ContainerManager:
    super manager

  start -> Container:
    // This container is already running as the system process.
    container := Container this 0 (current_process_)
    manager.on_container_start_ container
    return container

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
  boot container_manager
  // TODO(kasper): Should we reboot here after a little while?
