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

  // Kills the processes of the container, and returns whether there were any.
  kill-processes_ -> bool:
    if not pids_ or pids_.is-empty: return false
    pids_.do: container-kill-pid_ it
    return true

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

/**
Starts the combined program with the given $index in a container with the given
  $gid.

Programs can have other programs combined with them. Their main methods are
  entry points of the program, so they run in processes of their own, like
  other containers, but they share the code of the program.
*/
spawn-combined index/int gid/int arguments/any --id/uuid.Uuid --assets/ByteArray?=null -> int:
  // The new process starts at the entry for combined programs, which calls
  // the main method of the program with the given index. The id and the
  // assets are the ones of the container, because the program is the
  // system program.
  return spawn-entry_ gid id.to-byte-array [index, arguments] assets

spawn-entry_ gid/int id/ByteArray arguments/any assets/ByteArray? -> int:
  #primitive.programs-registry.spawn-entry

/**
Returns the images of the containers that run programs that are combined
  with the system program.

The firmware tooling describes them in the "combined" system asset, as a list
  with the name of each container, the index of its program in the order the
  programs are combined with the system program, its flags, its assets or
  null, and its id. The id is computed from the snapshot of its program and
  its assets, like the ids of other images, so the container has the same id
  as when it runs from its snapshot.
*/
combined-images_ manager/ContainerManager -> List:
  encoded := assets.decode.get "combined"
  if not encoded: return []
  described := tison.decode encoded
  count := combined-count_
  images := []
  for i := 0; i < described.size; i += 5:
    index := described[i + 1]
    if not 0 <= index < count:
      throw "The system program has $count combined programs, but a container runs program $index"
    images.add
        ContainerImageCombined manager index
            --flags=described[i + 2]
            --assets=described[i + 3]
            --id=uuid.Uuid described[i + 4]
  return images

/**
A container that runs a program that is combined with the system program.
  It runs in a container of its own, but it shares the code with the
  system program.

It is part of the firmware, so uninstalling it only marks it as uninstalled.
  See $ContainerManager.uninstall-firmware-image.
*/
class ContainerImageCombined extends ContainerImage:
  index/int
  id/uuid.Uuid
  flags/int
  assets/ByteArray?

  constructor manager/ContainerManager .index --.flags --.assets --.id:
    super manager

  spawn container/Container arguments/any -> int:
    return spawn-combined index container.id arguments --id=id --assets=assets

  stop-all -> none:
    // The processes stop asynchronously, so we wait until they have.
    while manager.kill-containers_ this: sleep --ms=10
    manager.on-image-stop-all_ this

  delete -> none:
    stop-all
    manager.uninstall-firmware-image this

/**
A container image that is bundled with the firmware.

It is part of the firmware, so uninstalling it only marks it as uninstalled.
  See $ContainerManager.uninstall-firmware-image.
*/
class ContainerImageBundled extends ContainerImageFlash:
  constructor manager/ContainerManager allocation/FlashAllocation:
    super manager allocation

  delete -> none:
    stop-all
    manager.uninstall-firmware-image this

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
  abstract lookup-firmware-image id/uuid.Uuid -> ContainerImage?
  abstract reinstall-firmware-image image/ContainerImage -> none
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
    if firmware-image := lookup-firmware-image allocation.id:
      // The firmware has the image already, so we use that instead and
      // throw the new one away. The id covers the program and its assets,
      // so they are the same.
      image-registry.free allocation
      reinstall-firmware-image firmware-image
      return firmware-image.id
    if not container-has-bytecodes_:
      // Native firmware can leave out the bytecode interpreter, and then it
      // can only run the containers in the firmware.
      image-registry.free allocation
      throw "This firmware can only run the containers in it"
    image := add-flash-image allocation
    return image.id

  notify-background-state-changed new-state/bool:
    unreachable  // Here to satisfy the checker.

class ContainerManager extends ContainerServiceProvider implements SystemMessageHandler_:
  image-registry/FlashRegistry ::= ?
  service-manager_/SystemServiceManager ::= ?

  images_/Map ::= {:}               // Map<uuid.Uuid, ContainerImage>
  // The images in the firmware that can be uninstalled, whether they are
  // installed or not, and the marks of the ones that are uninstalled.
  firmware-images_/Map ::= {:}      // Map<uuid.Uuid, ContainerImage>
  uninstalled_/Map ::= {:}          // Map<uuid.Uuid, FlashAllocation>
  containers-by-id_/Map ::= {:}     // Map<int, Container>
  containers-by-image_/Map ::= {:}  // Map<uuid.Uuid, Container>

  system-image_/ContainerImage? := null
  done_ ::= monitor.Latch

  constructor .image-registry .service-manager_:
    set-system-message-handler_ SYSTEM-TERMINATED_ this
    set-system-message-handler_ SYSTEM-SPAWNED_ this
    set-system-message-handler_ SYSTEM-TRACE_ this

    image-registry.do: | allocation/FlashAllocation |
      if allocation.type == FLASH-ALLOCATION-TYPE-PROGRAM:
        add-flash-image allocation
      else if allocation.type == FLASH-ALLOCATION-TYPE-UNINSTALLED:
        uninstalled_[allocation.id] = allocation

    // The images in the firmware are the bundled images in the VM and the
    // images of the programs that are combined with the system program.
    // Skip the first bundled image, which is always the system image.
    // Every image takes up two entries in the $bundled array: The first
    // entry is the address and the second is the size.
    firmware-images := []
    bundled := container-bundled-images_
    for i := 2; i < bundled.size; i += 2:
      firmware-images.add (ContainerImageBundled this (FlashAllocation bundled[i]))
    firmware-images.add-all (combined-images_ this)
    register-firmware-images_ firmware-images

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

  /**
  Registers the $images that are part of the firmware, except for the ones
    that are marked as uninstalled, and the ones that are also installed in
    flash.

  The marks are valid as long as installed programs are, so they can be
    from an earlier firmware with the same uuid. The marks of images that
    aren't in this firmware are freed, so they don't take up space forever.
  */
  register-firmware-images_ images/List -> none:
    images.do: | image/ContainerImage |
      firmware-images_[image.id] = image
      if uninstalled_.contains image.id or images_.contains image.id: continue.do
      register-image image
    unknown := uninstalled_.keys.filter: not firmware-images_.contains it
    unknown.do: | id/uuid.Uuid |
      image-registry.free (uninstalled_.get id)
      uninstalled_.remove id

  lookup-firmware-image id/uuid.Uuid -> ContainerImage?:
    return firmware-images_.get id

  /**
  Marks the firmware $image as uninstalled.

  The mark is an allocation in the flash registry, so it is written like
    other allocations: the header is written last, and the mark is only
    valid when all of it is written. Freeing it reinstalls the image.
  */
  uninstall-firmware-image image/ContainerImage -> none:
    if uninstalled_.contains image.id: return
    reservation := image-registry.reserve FLASH-REGISTRY-PAGE-SIZE
    if not reservation: throw "No space left in flash"
    uninstalled_[image.id] = image-registry.allocate reservation
        --type=FLASH-ALLOCATION-TYPE-UNINSTALLED
        --id=image.id
        --metadata=#[0, 0, 0, 0, 0]
    unregister-image image.id

  /**
  Reinstalls the firmware $image by freeing the mark that says that it is
    uninstalled.
  */
  reinstall-firmware-image image/ContainerImage -> none:
    mark/FlashAllocation? := uninstalled_.get image.id
    if not mark: return
    print_ "[toit] INFO: reinstalling container image $image.id from the firmware"
    image-registry.free mark
    uninstalled_.remove image.id
    register-image image

  // Kills the processes of the containers that run the $image, and returns
  // whether there were any.
  kill-containers_ image/ContainerImage -> bool:
    containers/Map? := containers-by-image_.get image.id
    if not containers: return false
    killed := false
    containers.do --values: | container/Container |
      if container.kill-processes_: killed = true
    return killed

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

container-has-bytecodes_ -> bool:
  #primitive.programs-registry.has-bytecodes
