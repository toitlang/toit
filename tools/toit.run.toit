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
import ..system.system_rpc_broker

import .mirror as mirror
import .snapshot as snapshot

class ContainerImageSnapshot extends ContainerImage:
  id/uuid.Uuid ::= ?
  bundle_/ByteArray ::= ?
  program_/snapshot.Program? := null

  constructor manager/ContainerManager .bundle_:
    id = uuid.uuid5 "fisk" "hest"  // TODO(kasper): Fix this.
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

  start -> Container:
    ar_reader := ArReader.from_bytes bundle_
    offsets := ar_reader.find --offsets snapshot.SnapshotBundle.SNAPSHOT_NAME
    gid ::= container_next_gid_
    pid ::= launch_snapshot_ bundle_[offsets.from..offsets.to] gid true
    container := Container this gid pid
    manager.on_container_start_ container
    return container

  on_container_error container/Container error/int -> none:
    // If a container started from the entry container image gets an error,
    // we exit eagerly.
    manager.terminate error

  stop_all -> none:
    unreachable  // Not implemented yet.

  delete -> none:
    unreachable  // Not implemented yet.

main:
  // The snapshot for the application program is passed in hatch_args_.
  snapshot_bundle ::= hatch_args_
  if snapshot_bundle is not ByteArray:
    print_on_stderr_ "toit.run.toit must be provided a snapshot"
    exit 1

  container_manager/ContainerManager := initialize
  image := ContainerImageSnapshot container_manager snapshot_bundle
  container_manager.register_image image
  exit (boot container_manager)

// ----------------------------------------------------------------------------

/**
Starts a new process using the given $snapshot.

Passes the arguments of this process if $pass_arguments is set.
*/
launch_snapshot_ snapshot/ByteArray gid/int pass_arguments/bool -> int:
  #primitive.snapshot.launch
