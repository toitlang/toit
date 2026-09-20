// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
import system.containers as client-containers

import .firmware
import .storage
import ...containers
import ...flash.registry
import ...services

class SystemImage extends ContainerImage:
  id ::= client-containers.current

  constructor manager/ContainerManager:
    super manager

  spawn container/Container arguments/any -> int:
    return Process.current.id

  stop-all -> none:
    throw "PERMISSION_DENIED"

  delete -> none:
    throw "PERMISSION_DENIED"

/** Installs platform services and tracks independently running containers. */
class Platform:
  containers/ContainerManager

  constructor:
    service-manager := SystemServiceManager
    (FirmwareServiceProvider).install
    registry := FlashRegistry.scan
    (StorageServiceProviderRp2350 registry).install
    containers = ContainerManager registry service-manager
    containers.register-system-image (SystemImage containers)
    containers.system-image.load.start

  start-containers -> none:
    containers.images.do: | image/ContainerImage |
      if image.run-boot: image.load.start
