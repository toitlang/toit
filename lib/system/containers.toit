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
import system.services show ServiceResourceProxy ServiceHandler

_client_ /ContainerServiceClient ::=
    (ContainerServiceClient).open as ContainerServiceClient

images -> List:
  return _client_.list-images

current -> uuid.Uuid:
  // TODO(kasper): It is unfortunate, but we have to copy
  // the id here because we cannot transfer non-disposable
  // external byte arrays across the RPC boundary.
  return uuid.Uuid current-image-id_.copy

start id/uuid.Uuid arguments/any=[] -> Container
    --on-event/Lambda?=null
    --on-stopped/Lambda?=null:
  image/List? := _client_.load-image id
  if not image: throw "No such container: $id"
  handle := image[0]
  gid := image[1]
  container := Container.internal_
      --handle=handle
      --id=id
      --gid=gid
      --on-event=on-event
      --on-stopped=on-stopped
  try:
    _client_.start-container handle arguments
    return container
  finally: | is-exception exception |
    if is-exception: container.close

uninstall id/uuid.Uuid -> none:
  _client_.uninstall-image id

/** Notifies the system about a background-state change. */
notify-background-state-changed new-state/bool -> none:
  _client_.notify-background-state-changed new-state

class ContainerImage:
  id/uuid.Uuid
  name/string?
  flags/int
  data/int
  constructor --.id --.name --.flags --.data:

class Container extends ServiceResourceProxy:
  static EVENT-BACKGROUND-STATE-CHANGE ::= 0

  // TODO(kasper): Rename this and document it.
  id/uuid.Uuid

  /**
  The $gid is shared among all processes that run within the
    same container. When a process invokes a service method,
    the $gid is passed to
    $(ServiceHandler.handle index arguments --gid --client)
    as a way to identify the running container that the
    invocation originates from.

  The container gets a new and unique $gid when it starts, but
    any process that is spawned from within the container gets
    the current $gid from its container.
  */
  gid/int

  result_/monitor.Latch ::= monitor.Latch
  on-event_/Lambda? := ?
  on-stopped_/Lambda? := ?

  constructor.internal_ --handle/int --.id --.gid --on-event/Lambda? --on-stopped/Lambda?:
    on-event_ = on-event
    on-stopped_ = on-stopped
    super _client_ handle --install-finalizer=(not (on-stopped or on-event))

  close -> none:
    catch --trace: throw "close"
    // Make sure anyone waiting for the result now or in the future
    // knows that we got closed before getting an exit code.
    if not result_.has-value: result_.set null
    super

  stop -> int:
    _client_.stop-container handle_
    return wait

  wait -> int:
    code/int? := result_.get
    if not code: throw "CLOSED"
    return code

  /// Deprecated.
  on-stopped lambda/Lambda? -> none:
    if not lambda:
      on-stopped_ = null
      return
    if on-stopped_: throw "ALREADY_IN_USE"
    if result_.has-value:
      code := result_.get
      if not code: throw "CLOSED"
      lambda.call code
    else:
      on-stopped_ = lambda

  /// Deprecated.
  on-event lambda/Lambda? -> none:
    if not lambda:
      on-event_ = null
      return
    if on-event_: throw "ALREADY_IN_USE"
    on-event_ = lambda

  on-notified_ notification/any -> none:
    if notification is int:
      code/int := notification
      result_.set code
      on-stopped := on-stopped_
      on-stopped_ = null
      if on-stopped: on-stopped.call code
      // We no longer expect or care about notifications, so
      // close the resource.
      close
    else if on-event_:
      if notification is not List or notification.size != 2 or notification[0] is not int:
        // Discard unknown event.
        return
      event-kind := notification[0]
      event-value := notification[1]
      on-event_.call event-kind event-value

class ContainerImageWriter extends ServiceResourceProxy:
  size/int ::= ?

  constructor .size:
    super _client_ (_client_.image-writer-open size)

  write bytes/ByteArray -> none:
    _client_.image-writer-write handle_ bytes

  commit -> uuid.Uuid
      --data/int=0
      --run-boot/bool=false
      --run-critical/bool=false:
    flags := 0
    if run-boot: flags |= ContainerService.FLAG-RUN-BOOT
    if run-critical: flags |= ContainerService.FLAG-RUN-CRITICAL
    return _client_.image-writer-commit handle_ flags data

// ----------------------------------------------------------------------------

current-image-id_ -> ByteArray:
  #primitive.image.current-id
