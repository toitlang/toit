// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
import system.containers
import .storage show StorageServiceProviderZephyr
import ...boot
import ...containers
import ...flash.registry
import ...services

class SystemImage extends ContainerImage:
  id ::= containers.current

  constructor manager/ContainerManager:
    super manager

  spawn container/Container arguments/any -> int:
    return Process.current.id

  stop-all -> none:
    throw "Cannot stop the system container"

  delete -> none:
    throw "Cannot delete the system container"

main:
  registry := FlashRegistry.scan
  services := SystemServiceManager
  (StorageServiceProviderZephyr registry).install
  manager := ContainerManager registry services
  manager.register-system-image (SystemImage manager)
  exit (boot manager)
