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
import system.services show ServiceProvider

import .firmware
import .storage show StorageServiceProviderEsp32
import .wifi

import ...boot
import ...containers
import ...flash.registry
import ...services

// TODO(kasper): It feels annoying to have to put this here. Maybe we
// can have some sort of reasonable default in the ContainerManager?
class SystemImage extends ContainerImage:
  id ::= containers.current

  constructor manager/ContainerManager:
    super manager

  spawn container/Container arguments/any -> int:
    // This container is already running as the system process.
    return Process.current.id

  stop-all -> none:
    unreachable  // Not implemented yet.

  delete -> none:
    unreachable  // Not implemented yet.

main:
  registry ::= FlashRegistry.scan
  service-manager ::= SystemServiceManager
  (FirmwareServiceProvider).install
  (StorageServiceProviderEsp32 registry).install
  (WifiServiceProvider).install
  container-manager := ContainerManager registry service-manager
  system-image := SystemImage container-manager
  container-manager.register-system-image system-image
  exit (boot container-manager)
