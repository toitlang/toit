// Copyright (C) 2024 Toitware ApS.
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

import host.file
import host.directory

import system.containers

import ..system.boot
import ..system.containers
import ..system.flash.registry
import ..system.initialize

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

add-image path/string -> none:
  image-data := file.read-content path
  writer := containers.ContainerImageWriter image-data.size
  writer.write image-data
  writer.commit --run-boot --run-critical

main arguments:
  registry ::= FlashRegistry.scan
  container-manager ::= initialize-system registry [
  ]
  container-manager.register-system-image (SystemImage container-manager)

  if arguments.is-empty:
    print_ "Usage: run-image <image|directory>"
    exit 1

  arg := arguments.first
  if file.is-file arg:
    add-image arg
  else if file.is-directory arg:
    stream := directory.DirectoryStream arg
    try:
      while file-name/string? := stream.next:
        path := "$arg/$file-name"
        if file.is-file path:
          add-image path
    finally:
      stream.close
  else:
    print_ "Invalid argument: $arg"
    exit 1

  exit (boot container-manager)
