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

import .flash.registry
import .containers
import .services

/**
Initialize the system and create the all important $ContainerManager
  instance.
*/
initialize-system registry/FlashRegistry extensions/List -> ContainerManager:
  print_ "[toit] initialize system"
  service-manager ::= SystemServiceManager
  print_ "[toit] installing $extensions.size extensions"
  extensions.do: | provider/ServiceProvider |
    print_ "[toit] installing extension: $provider.name"
    provider.install
    print_ "[toit] installing extension: $provider.name -> done"
  return ContainerManager registry service-manager
