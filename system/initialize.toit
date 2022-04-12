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

import system.services show ServiceDefinition

import .flash.registry
import .containers
import .services

/**
Initialize the system and create the all important $ContainerManager
  instance.
*/
initialize_system extensions/List -> ContainerManager:
  flash_registry ::= FlashRegistry.scan
  service_manager ::= SystemServiceManager
  extensions.do: | service/ServiceDefinition | service.install
  return ContainerManager flash_registry service_manager
