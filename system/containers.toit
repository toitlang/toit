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

import io show LITTLE-ENDIAN
import uuid
import monitor

import encoding.base64
import encoding.tison

import system.assets
import system.services show ServiceHandler ServiceProvider ServiceResource
import system.api.containers show ContainerService
import system.containers as system-containers

import .flash.allocation
import .flash.image-writer
import .flash.registry
import .flash.reservation
import .services

class Container:
  image/ContainerImage ::= ?
  gid_/int ::= ?
  pids_/Set? := null
  resources/Set ::= {}

  constructor .image .gid_:

  id -> int:
    return gid_

  is-process-running pid/int -> bool:
    return pids_.contains pid

  start arguments/any=image.default-arguments -> none:
    if pids_: throw "Already started"
    pids_ = {image.spawn this arguments}

  stop -> none:
    if not pids_: throw "Not started"
    if pids_.is-empty: return
    pids_.do: container-kill-pid_ it
    pids_.clear
    image.manager.on-container-stop_ this 0
    resources.do: it.on-container-stop 0

  send-event event/any:
    if not pids_: throw "Not started"
    if pids_.is-empty: return
    resources.do: it.send-event event

  on-stop_ -> none:
    pids_.do: on-process-stop_ it 0

  on-process-start_ pid/int -> none:
    assert: not pids_.is-empty
    pids_.add pid

  on-process-stop_ pid/int error/int -> none:
    pids_.remove pid
    if error != 0:
      pids_.do: container-kill-pid_ it
      pids_.clear
    else if not pids_.is-empty:
      return
    image.manager.on-container-stop_ this error
    resources.do: it.on-container-stop error

class ContainerResource extends ServiceResource:
  container/Container
  hash-code/int ::= hash-code-next

  constructor .container provider/ServiceProvider client/int:
    super provider client --notifiable
    container.resources.add this

  static hash-code-next_/int := 0
  static hash-code-next -> int:
    next := hash-code-next_
    hash-code-next_ = (next + 1) & 0x1fff_ffff
    return next

  on-container-stop code/int -> none:
    if is-closed: return
    notify_ code

  send-event event/List -> none:
    if is-closed: return
    notify_ event

  on-closed -> none:
    container.resources.remove this

abstract class ContainerImage:
  manager/ContainerManager ::= ?
  constructor .manager:

  abstract id -> uuid.Uuid

  load -> Container:
    // We load the container without starting it, so we can
    // register the container correctly before we receive the
    // first events from it. This avoids a race condition
    // that could occur because spawning a new process is
    // inherently asynchronous and we need the client and the
    // container manager to be ready for processing messages
    // and close notifications.
    gid ::= container-next-gid_
    container := Container this gid
    manager.on-container-load_ container
    return container

  trace encoded/ByteArray -> bool:
    return false

  flags -> int:
    return 0

  data -> int:
    return 0

  run-boot -> bool:
    return flags & ContainerService.FLAG-RUN-BOOT != 0

  run-critical -> bool:
    return flags & ContainerService.FLAG-RUN-CRITICAL != 0

  default-arguments -> any:
    // TODO(kasper): For now, the default arguments passed
    // to a container on start is an empty list. We could
    // consider making it null instead.
    return []

  abstract spawn container/Container arguments/any -> int
  abstract stop-all -> none
  abstract delete -> none

class ContainerImageFlash extends ContainerImage:
  allocation_/FlashAllocation? := ?

  constructor manager/ContainerManager .allocation_:
    super manager

  id -> uuid.Uuid:
    return allocation_.id

  flags -> int:
    return allocation_.metadata[0]

  data -> int:
    return LITTLE-ENDIAN.uint32 allocation_.metadata 1

  spawn container/Container arguments/any:
    return container-spawn_ allocation_.offset container.id arguments

  stop-all -> none:
    attempts := 0
    while container-is-running_ allocation_.offset:
      result := container-kill-flash-image_ allocation_.offset
      if result: attempts++
      sleep --ms=10
    manager.on-image-stop-all_ this

  delete -> none:
    stop-all
    // TODO(kasper): We clear the allocation field, so maybe we should check for
    // null in the methods that use the field?
    allocation := allocation_
    allocation_ = null
    try:
      manager.unregister-image allocation.id
    finally:
      manager.image-registry.free allocation

abstract class ContainerServiceProvider extends ServiceProvider
    implements ContainerService ServiceHandler:

  constructor:
    super "system/containers" --major=0 --minor=2
    provides ContainerService.SELECTOR --handler=this
    install

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == ContainerService.LIST-IMAGES-INDEX:
      return list-images
    if index == ContainerService.LOAD-IMAGE-INDEX:
      return load-image client (uuid.Uuid arguments)
    if index == ContainerService.START-CONTAINER-INDEX:
      resource ::= (resource client arguments[0]) as ContainerResource
      return start-container resource arguments[1]
    if index == ContainerService.STOP-CONTAINER-INDEX:
      resource ::= (resource client arguments) as ContainerResource
      return stop-container resource
    if index == ContainerService.UNINSTALL-IMAGE-INDEX:
      return uninstall-image (uuid.Uuid arguments)
    if index == ContainerService.IMAGE-WRITER-OPEN-INDEX:
      return image-writer-open client arguments
    if index == ContainerService.IMAGE-WRITER-WRITE-INDEX:
      writer ::= (resource client arguments[0]) as ContainerImageWriter
      return image-writer-write writer arguments[1]
    if index == ContainerService.IMAGE-WRITER-COMMIT-INDEX:
      writer ::= (resource client arguments[0]) as ContainerImageWriter
      return (image-writer-commit writer arguments[1] arguments[2]).to-byte-array
    if index == ContainerService.NOTIFY-BACKGROUND-STATE-CHANGED-INDEX:
      return send-container-event --gid=gid
          system-containers.Container.EVENT-BACKGROUND-STATE-CHANGE
          arguments
    unreachable

  abstract image-registry -> FlashRegistry
  abstract images -> List
  abstract add-flash-image allocation/FlashAllocation -> ContainerImage
  abstract lookup-image id/uuid.Uuid -> ContainerImage?
  abstract send-container-event --gid/int event-kind/int event-value/any -> none

  list-images -> List:
    names := {:}
    assets.decode.get "images" --if-present=: | encoded |
      map := tison.decode encoded
      map.do: | name/string id/ByteArray | names[uuid.Uuid id] = name
    raw := images
    result := []
    raw.do: | image/ContainerImage |
      id/uuid.Uuid := image.id
      result.add id.to-byte-array
      result.add (names.get id)
      result.add image.flags
      result.add image.data
    return result

  load-image id/uuid.Uuid -> List?:
    unreachable  // <-- TODO(kasper): Nasty.

  load-image client/int id/uuid.Uuid -> List?:
    image/ContainerImage? := lookup-image id
    if not image: return null
    container := image.load
    resource := ContainerResource container this client
    return [resource.serialize-for-rpc, container.id]

  start-container resource/ContainerResource arguments/any -> none:
    resource.container.start arguments

  stop-container resource/ContainerResource -> none:
    resource.container.stop

  uninstall-image id/uuid.Uuid -> none:
    image/ContainerImage? := lookup-image id
    if not image: return
    image.delete

  image-writer-open size/int -> int:
    unreachable  // <-- TODO(kasper): Nasty.

  image-writer-open client/int size/int -> ServiceResource:
    relocated-size := size - (size / IMAGE-CHUNK-SIZE) * IMAGE-WORD-SIZE
    reservation := image-registry.reserve relocated-size
    if not reservation: throw "No space left in flash"
    return create-container-image-writer_ client reservation

  /**
  Creates a new container image writer service resource.

  # Inheritance
  This method may be overridden by subclasses to provide a custom
    implementation of the `ContainerImageWriter` service resource.
  */
  create-container-image-writer_ client/int reservation/FlashReservation -> ContainerImageWriter:
    return ContainerImageWriter this client reservation

  image-writer-write writer/ContainerImageWriter bytes/ByteArray -> none:
    writer.write bytes

  image-writer-commit writer/ContainerImageWriter flags/int data/int -> uuid.Uuid:
    allocation := writer.commit --flags=flags --data=data
    image := add-flash-image allocation
    return image.id

  notify-background-state-changed new-state/bool:
    unreachable  // Here to satisfy the checker.

class ContainerManager extends ContainerServiceProvider implements SystemMessageHandler_:
  image-registry/FlashRegistry ::= ?
  service-manager_/SystemServiceManager ::= ?

  images_/Map ::= {:}               // Map<uuid.Uuid, ContainerImage>
  containers-by-id_/Map ::= {:}     // Map<int, Container>
  containers-by-image_/Map ::= {:}  // Map<uuid.Uuid, Container>

  system-image_/ContainerImage? := null
  done_ ::= monitor.Latch

  constructor .image-registry .service-manager_:
    set-system-message-handler_ SYSTEM-TERMINATED_ this
    set-system-message-handler_ SYSTEM-SPAWNED_ this
    set-system-message-handler_ SYSTEM-TRACE_ this

    image-registry.do: | allocation/FlashAllocation |
      if allocation.type != FLASH-ALLOCATION-TYPE-PROGRAM: continue.do
      add-flash-image allocation

    // Run through the bundled images in the VM, but skip the
    // first one which is always the system image. Every image
    // takes up two entries in the $bundled array: The first
    // entry is the address and the second is the size.
    bundled := container-bundled-images_
    for i := 2; i < bundled.size; i += 2:
      allocation := FlashAllocation bundled[i]
      if not images_.contains allocation.id: add-flash-image allocation

  system-image -> ContainerImage:
    return system-image_

  images -> List:
    return images_.values.filter: it != system-image_

  lookup-image id/uuid.Uuid -> ContainerImage?:
    return images_.get id

  register-image image/ContainerImage -> none:
    images_[image.id] = image

  register-system-image image/ContainerImage -> none:
    register-image image
    system-image_ = image

  unregister-image id/uuid.Uuid -> none:
    images_.remove id

  lookup-container id/int -> Container?:
    return containers-by-id_.get id

  add-flash-image allocation/FlashAllocation -> ContainerImage:
    image := ContainerImageFlash this allocation
    register-image image
    return image

  // TODO(kasper): Not so happy with this name.
  wait-until-done -> int:
    if containers-by-id_.is-empty: return 0
    return done_.get

  on-container-load_ container/Container -> none:
    containers/Map ::= containers-by-image_.get container.image.id --init=: {:}
    containers[container.id] = container
    containers-by-id_[container.id] = container

  on-container-stop_ container/Container error/int -> none:
    containers-by-id_.remove container.id
    // If we've got an error in an image that run with the run.critical
    // flag, we treat that as a fatal error and terminate the system process.
    if error != 0 and container.image.run-critical:
      done_.set error
      return
    // TODO(kasper): We are supposed to always have a running system process. Maybe
    // we can generalize this handling and support background processes that do not
    // restrict us from exiting?
    remaining ::= containers-by-id_.size
    if remaining <= 1 and not done_.has-value: done_.set 0

  on-image-stop-all_ image/ContainerImage -> none:
    containers/Map? ::= containers-by-image_.get image.id
    containers-by-image_.remove image.id
    if containers:
      containers.do: | id/int container/Container |
        container.on-stop_

  on-message type/int gid/int pid/int arguments/any -> none:
    container/Container? := lookup-container gid
    if type == SYSTEM-TERMINATED_:
      service-manager_.on-process-stop pid
      if container:
        error/int := arguments
        container.on-process-stop_ pid error
    else if type == SYSTEM-SPAWNED_:
      if container: container.on-process-start_ pid
    else if type == SYSTEM-TRACE_:
      origin-id/uuid.Uuid? ::= trace-find-origin-id arguments
      origin/ContainerImage? ::= origin-id and lookup-image origin-id
      if not (origin and origin.trace arguments):
        trace-using-print arguments
    else:
      unreachable

  send-container-event --gid/int event-kind/int event-value/any -> none:
    container/Container? := lookup-container gid
    if container: container.send-event [event-kind, event-value]

trace-using-print message/ByteArray --from=0 --to=message.size:
  // Print a trace message on output so that that you can easily decode.
  // The message is base64 encoded to limit the output size.
  print_ "----"
  print_ "Received a Toit system message. Executing the command below will"
  print_ "make it human readable:"
  print_ "----"
  // Block size must be a multiple of 3 for this to work, due to the 3/4 nature
  // of base64 encoding.
  BLOCK-SIZE := 1500
  for i := from; i < to; i += BLOCK-SIZE:
    end := i >= to - BLOCK-SIZE
    prefix := i == from ? "jag decode " : ""
    base64-text := base64.encode message[i..(end ? to : i + BLOCK-SIZE)]
    postfix := end ? "\n" : ""
    write-on-stdout_ "$prefix$base64-text$postfix" false

trace-find-origin-id trace/ByteArray -> uuid.Uuid?:
  // Short strings are encoded with a single unsigned byte length ('U').
  skip-string ::= : | p |
    if trace[p] != 'S' or trace[p + 1] != 'U': return null
    p + trace[p + 2] + 3

  catch --no-trace:
    // The trace is a ubjson encoded array with 5 elements. The first entry
    // is an integer encoding of the 'X' character.
    if trace[0..6] != #['[', '#', 'U', 5, 'U', 'X']: return null
    // The next two entries are short version strings.
    position := skip-string.call 6
    position = skip-string.call position
    // The fourth entry is the byte array for the program id.
    if trace[position..position + 6] != #['[', '$', 'U', '#', 'U', 16]: return null
    return uuid.Uuid trace[position + 6..position + 22]
  return null

// ----------------------------------------------------------------------------

container-spawn_ offset gid arguments -> int:
  #primitive.programs-registry.spawn

container-is-running_ offset -> bool:
  #primitive.programs-registry.is-running

container-kill-flash-image_ offset -> bool:
  #primitive.programs-registry.kill

container-next-gid_ -> int:
  #primitive.programs-registry.next-group-id

container-kill-pid_ pid/int -> bool:
  #primitive.core.process-signal-kill

container-bundled-images_ -> Array_:
  #primitive.programs-registry.bundled-images
