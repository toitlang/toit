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
import system.api.containers show ContainerService

import ..system.boot
import ..system.containers
import ..system.extensions.host.initialize

import .mirror as mirror
import .snapshot show Program SnapshotBundle

abstract class ContainerImageFromSnapshot extends ContainerImage:
  bundle_/ByteArray ::= ?
  program_/Program? := null
  id/uuid.Uuid? := null

  constructor manager/ContainerManager .bundle_:
    super manager
    reader := ArReader.from_bytes bundle_
    initialize reader

  initialize reader/ArReader -> none:
    // The reader might not be at the beginning of the archive anymore.
    // For an application image, the initialize already consumed the
    // snapshot.
    offsets := reader.find --offsets SnapshotBundle.UUID_NAME
    id = uuid.Uuid bundle_[offsets.from..offsets.to]

  trace encoded/ByteArray -> bool:
    // Parse the snapshot lazily the first time debugging information is needed.
    if not program_: program_ = (SnapshotBundle bundle_).decode
    // Decode the stack trace.
    mirror ::= mirror.decode encoded program_: return false
    mirror_string := mirror.stringify
    // If the text already ends with a newline don't add another one.
    write_on_stderr_ mirror_string (not mirror_string.ends_with "\n")
    return true

  stop_all -> none:
    unreachable  // Not implemented yet.

  delete -> none:
    unreachable  // Not implemented yet.

class SystemContainerImage extends ContainerImageFromSnapshot:
  constructor manager/ContainerManager bundle/ByteArray:
    super manager bundle

  spawn container/Container arguments/any -> int:
    // This container is already running as the system process.
    return Process.current.id

class ApplicationContainerImage extends ContainerImageFromSnapshot:
  snapshot/ByteArray? := null
  flags ::= ContainerService.FLAG_RUN_BOOT | ContainerService.FLAG_RUN_CRITICAL

  // Arguments passed to main in the system process are automatically
  // forwarded to the application process on boot.
  default_arguments/any

  constructor manager/ContainerManager bundle/ByteArray .default_arguments:
    super manager bundle

  initialize reader/ArReader -> none:
    offsets := reader.find --offsets SnapshotBundle.SNAPSHOT_NAME
    snapshot = bundle_[offsets.from..offsets.to]
    // We must read the $id last because it comes after the snapshot in
    // the archive.
    super reader

  spawn container/Container arguments/any -> int:
    return launch_snapshot_ snapshot container.id id.to_byte_array arguments

  static launch_snapshot_ snapshot/ByteArray gid/int id/ByteArray arguments/any -> int:
    #primitive.snapshot.launch

main arguments:
  // The snapshot bundles for the system and application programs are passed in the
  // spawn arguments.
  bundles/Array_ ::= spawn_arguments_
  system_bundle ::= bundles[0]
  application_bundle ::= bundles[1]
  if application_bundle is not ByteArray:
    print_on_stderr_ "toit.run.toit must be provided a snapshot"
    exit 1

  container_manager/ContainerManager := initialize_host
  container_manager.register_system_image
      SystemContainerImage container_manager system_bundle
  container_manager.register_image
      ApplicationContainerImage container_manager application_bundle arguments
  exit (boot container_manager)
