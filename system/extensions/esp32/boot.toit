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
import ...storage
import ...flash.registry

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
  print_ "[toit] scanning flash registry"
  registry ::= FlashRegistry.scan

  print_ "[toit] create firmware service"
  p0 := FirmwareServiceProvider
  print_ "[toit] create storage service"
  p1 := StorageServiceProvider registry
  print_ "[toit] create wifi service"
  p2 := WifiServiceProvider
  print_ "[toit] done creating services"
  container-manager ::= initialize-system registry [
      p0,
      p1,
      p2,
  ]
  container-manager.register-system-image
      SystemImage container-manager

  print_ "[toit] start user code"
  exit (boot container-manager)
