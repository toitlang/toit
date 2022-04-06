// Copyright (C) 2019 Toitware ApS.
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

import ar show *
import uuid

import ..system.boot
import ..system.containers
import ..system.extensions.host.initialize

import .mirror as mirror
import .snapshot as snapshot

abstract class ContainerImageFromSnapshot extends ContainerImage:
  id/uuid.Uuid ::= ?
  bundle_/ByteArray ::= ?
  program_/snapshot.Program? := null

  constructor manager/ContainerManager .bundle_ .id:
    super manager

  trace encoded/ByteArray -> bool:
    // Parse the snapshot lazily the first time debugging information is needed.
    if not program_: program_ = (snapshot.SnapshotBundle bundle_).decode
    // Decode the stack trace.
    mirror ::= mirror.decode encoded program_: return false
    mirror_string := mirror.stringify
    // If the text already ends with a newline don't add another one.
    write_on_stderr_ mirror_string (not mirror_string.ends_with "\n")
    return true

  abstract start -> Container

  on_container_error container/Container error/int -> none:
    // If a container started from the entry container image gets an error,
    // we exit eagerly.
    manager.terminate error

  stop_all -> none:
    unreachable  // Not implemented yet.

  delete -> none:
    unreachable  // Not implemented yet.

class SystemContainerImage extends ContainerImageFromSnapshot:
  constructor manager/ContainerManager bundle/ByteArray:
    super manager bundle uuid.NIL

  start -> Container:
    // This container is already running as the system process.
    container := Container this 0 (current_process_)
    manager.on_container_start_ container
    return container

class ApplicationContainerImage extends ContainerImageFromSnapshot:
  constructor manager/ContainerManager bundle/ByteArray:
    super manager bundle (uuid.uuid5 "fisk" "hest")  // TODO(kasper): Use a better id.

  start -> Container:
    ar_reader := ArReader.from_bytes bundle_
    offsets := ar_reader.find --offsets snapshot.SnapshotBundle.SNAPSHOT_NAME
    gid ::= container_next_gid_
    pid ::= launch_snapshot_ bundle_[offsets.from..offsets.to] gid id.to_byte_array
    container := Container this gid pid
    manager.on_container_start_ container
    return container

  static launch_snapshot_ snapshot/ByteArray gid/int id/ByteArray -> int:
    #primitive.snapshot.launch

main:
  // The snapshot bundles for the system and application programs are passed in the
  // spawn arguments.
  bundles/Array_ ::= spawn_arguments_
  system_bundle := bundles[0]
  application_bundle := bundles[1]
  if application_bundle is not ByteArray:
    print_on_stderr_ "toit.run.toit must be provided a snapshot"
    exit 1

  container_manager/ContainerManager := initialize_host
  container_manager.register_system_image
      SystemContainerImage container_manager system_bundle
  container_manager.register_image
      ApplicationContainerImage container_manager application_bundle
  exit (boot container_manager)
