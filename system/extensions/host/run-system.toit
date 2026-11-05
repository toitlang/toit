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

import .initialize
import ...boot
import ...containers
import ....tools.mirror as mirror
import ....tools.system-message_ as system-message
import ....tools.snapshot show Program SnapshotBundle

abstract class ContainerImageFromSnapshot extends ContainerImage:
  bundle-bytes_/ByteArray ::= ?
  program_/Program? := null
  has-looked-for-source-map_/bool := false
  id/uuid.Uuid? := null

  constructor manager/ContainerManager .bundle-bytes_:
    super manager
    reader := ArReader.from-bytes bundle-bytes_
    initialize reader

  initialize reader/ArReader -> none:
    // The reader might not be at the beginning of the archive anymore.
    // For an application image, the initialize already consumed the
    // snapshot.
    offsets := reader.find --offsets SnapshotBundle.UUID-NAME
    id = uuid.Uuid bundle-bytes_[offsets.from..offsets.to]

  trace encoded/ByteArray -> bool:
    catch:
      // Parse the source map lazily the first time debugging information is needed.
      if not has-looked-for-source-map_:
        has-looked-for-source-map_ = true
        source-map := SnapshotBundle.source-map-in bundle-bytes_
        if source-map: program_ = Program.from-source-map source-map

      // Decode the stack trace.
      // Without a program we might only get the exception, but no stack trace.
      message := system-message.decode-system-message encoded --if-error=: return false
      mirror ::= mirror.decode message.payload program_ --if-error=: return false
      mirror-string := mirror.stringify
      // If the text already ends with a newline don't add another one.
      write-on-stderr_ mirror-string (not mirror-string.ends-with "\n")
      // If we didn't have a program we want the caller to print a base64
      // encoded version of the stack trace.
      return program_ != null
    return false

  stop-all -> none:
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
  flags ::= ContainerService.FLAG-RUN-BOOT | ContainerService.FLAG-RUN-CRITICAL

  // Arguments passed to main in the system process are automatically
  // forwarded to the application process on boot.
  default-arguments/any

  constructor manager/ContainerManager bundle/ByteArray .default-arguments:
    super manager bundle

  initialize reader/ArReader -> none:
    offsets := reader.find --offsets SnapshotBundle.SNAPSHOT-NAME
    snapshot = bundle-bytes_[offsets.from..offsets.to]
    // We must read the $id last because it comes after the snapshot in
    // the archive.
    super reader

  spawn container/Container arguments/any -> int:
    return launch-snapshot_ snapshot container.id id.to-byte-array arguments

  static launch-snapshot_ snapshot/ByteArray gid/int id/ByteArray arguments/any -> int:
    #primitive.snapshot.launch

// An application that is compiled into the system program. It shares the
// program, and with it the debugging information, with the system.
class CombinedContainerImage extends ContainerImageFromSnapshot:
  index/int
  flags ::= ContainerService.FLAG-RUN-BOOT | ContainerService.FLAG-RUN-CRITICAL
  default-arguments/any

  constructor manager/ContainerManager system-bundle/ByteArray .index .default-arguments:
    super manager system-bundle
    // The images must have different ids, so the applications don't get the
    // id of the system program.
    id = uuid.Uuid.uuid5 "toit-combined-entry" "$id/$index"

  spawn container/Container arguments/any -> int:
    return spawn-combined index container.id arguments --id=id

/**
Runs the system program.

The snapshot bundles for the system and application programs are passed in
  the spawn arguments. With $combined, the applications are compiled into the
  system program instead, so there is no application bundle. See
  toit.run-combined.toit.
*/
run-system arguments --combined/bool=false -> none:
  bundles/Array_ ::= spawn-arguments_
  system-bundle ::= bundles[0]
  application-bundle ::= bundles[1]
  if not combined and application-bundle is not ByteArray:
    print-on-stderr_ "toit.run.toit must be provided a snapshot"
    exit 1

  container-manager/ContainerManager := initialize-host
  container-manager.register-system-image
      SystemContainerImage container-manager system-bundle
  if combined:
    combined-count_.repeat: | index |
      container-manager.register-image
          CombinedContainerImage container-manager system-bundle index arguments
  else:
    container-manager.register-image
        ApplicationContainerImage container-manager application-bundle arguments
  exit (boot container-manager)
