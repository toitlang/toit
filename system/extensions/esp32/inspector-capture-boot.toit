// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import esp32
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

// This boot entry is only used by the real-device inspector capture build.
// It preserves the normal ESP32 system setup and performs one terminal memory
// dump after boot containers have had time to initialize.

class SystemImage extends ContainerImage:
  id ::= containers.current

  constructor manager/ContainerManager:
    super manager

  spawn container/Container arguments/any -> int:
    return Process.current.id

  stop-all -> none:
    unreachable

  delete -> none:
    unreachable

main:
  task::
    sleep --ms=15_000
    esp32.dump-memory

  registry ::= FlashRegistry.scan
  service-manager ::= SystemServiceManager
  (FirmwareServiceProvider).install
  (StorageServiceProviderEsp32 registry).install
  (WifiServiceProvider).install
  container-manager := ContainerManager registry service-manager
  system-image := SystemImage container-manager
  container-manager.register-system-image system-image
  exit (boot container-manager)
