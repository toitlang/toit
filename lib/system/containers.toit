// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
User-space side of the RPC API for installing container images in flash, and
  stopping and starting containers based on them.
*/

import uuid
import monitor

import system.api.containers show ContainerService ContainerServiceClient
import system.services show ServiceResourceProxy

_client_ /ContainerServiceClient ::= ContainerServiceClient

images -> List:
  return _client_.list_images

current -> uuid.Uuid:
  return uuid.Uuid current_image_id_

start id/uuid.Uuid -> Container:
  handle/int? := _client_.start_image id
  if handle: return Container id handle
  throw "No such container: $id"

uninstall id/uuid.Uuid -> none:
  _client_.uninstall_image id

class ContainerImage:
  id/uuid.Uuid
  flags/int
  constructor .id .flags:

class Container extends ServiceResourceProxy:
  id/uuid.Uuid
  result_/monitor.Latch ::= monitor.Latch

  constructor .id handle/int:
    super _client_ handle

  close -> none:
    // Make sure anyone waiting for the result now or in the future
    // knows that we got closed before getting an exit code.
    if not result_.has_value: result_.set null
    super

  stop -> int:
    _client_.stop_container handle_
    return wait

  wait -> int:
    code/int? := result_.get
    if not code: throw "CLOSED"
    return code

  on_notified_ code/int -> none:
    result_.set code
    // We close the resource, because we no longer care about or expect
    // notifications. Closing involves RPCs and thus waiting for replies
    // which isn't allowed in the message processing context that runs
    // the $on_notified_ method. For that reason, we create a new task.
    close

class ContainerImageWriter extends ServiceResourceProxy:
  size/int ::= ?

  constructor .size:
    super _client_ (_client_.image_writer_open size)

  write bytes/ByteArray -> none:
    _client_.image_writer_write handle_ bytes

  commit -> uuid.Uuid
      --run_boot/bool=false
      --run_critical/bool=false:
    flags := 0
    if run_boot: flags |= ContainerService.FLAG_RUN_BOOT
    if run_critical: flags |= ContainerService.FLAG_RUN_CRITICAL
    return _client_.image_writer_commit handle_ flags

// ----------------------------------------------------------------------------

current_image_id_ -> ByteArray:
  #primitive.image.current_id
