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

import system.services show ServiceProvider

import .network
import .storage

import ...containers
import ...flash.registry
import ...services

initialize-host -> ContainerManager:
  registry ::= FlashRegistry.scan
  service-manager ::= SystemServiceManager
  (NetworkServiceProvider).install
  (StorageServiceProviderHost registry).install
  return ContainerManager registry service-manager
