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

import uuid
import monitor
import encoding.base64 as base64

import system.services show ServiceDefinition
import system.api.containers show ContainersService

import .flash.allocation
import .flash.image_writer
import .flash.registry
import .services

class Container:
  image/ContainerImage ::= ?
  gid_/int ::= ?

  // We keep the closeable descriptors registered in a map under the pid that
  // opened them. This allows us to call 'close' on the associated objects
  // automatically when processes terminate.
  pids_/Map ::= {:}  // Map<int, Map<int, Object>>

  constructor .image .gid_ pid/int:
    pids_[pid] = {:}

  id -> int:
    return gid_

  on_stop_ -> none:
    pids_.do --keys: on_process_stop_ it

  on_process_start_ pid/int -> none:
    assert: not pids_.is_empty
    pids_.get pid --init=: {:}

  on_process_stop_ pid/int -> none:
    // TODO(kasper): This is an ugly mess. Rewrite.
    descriptors := pids_.get pid
    pids_.remove pid
    if not descriptors or descriptors.is_empty:
      if pids_.is_empty: image.manager.on_container_stop_ this
      return
    pending/int := descriptors.size
    descriptors.do: | handle/int descriptor |
      // TODO(kasper): Avoid generating a new task for each descriptor.
      task::
        catch --trace:
          descriptor.close  // This needs to run in a separate task, because it may sleep, block.
        pending--
        if pending == 0:
          if pids_.is_empty: image.manager.on_container_stop_ this

  on_process_error_ pid/int error/int -> none:
    on_process_stop_ pid
    pids_.do --keys: container_kill_pid_ it
    image.on_container_error this error

abstract class ContainerImage:
  manager/ContainerManager ::= ?
  constructor .manager:

  abstract id -> uuid.Uuid

  trace encoded/ByteArray -> bool:
    return false

  // TODO(kasper): This isn't super nice. It feels a bit odd that the
  // image is told that one of its containers has an error.
  on_container_error container/Container error/int -> none:
    // Nothing so far.

  abstract start -> Container
  abstract stop_all -> none
  abstract delete -> none

class ContainerImageFlash extends ContainerImage:
  allocation_/FlashAllocation? := ?

  constructor manager/ContainerManager .allocation_:
    super manager

  id -> uuid.Uuid:
    return allocation_.id

  start -> Container:
    gid ::= container_next_gid_
    pid ::= container_spawn_ allocation_.offset allocation_.size gid
    // TODO(kasper): Can the container stop before we even get it created?
    container := Container this gid pid
    manager.on_container_start_ container
    return container

  stop_all -> none:
    attempts := 0
    while container_is_running_ allocation_.offset allocation_.size:
      result := container_kill_flash_image_ allocation_.offset allocation_.size
      if result: attempts++
      sleep --ms=10
    manager.on_image_stop_all_ this

  delete -> none:
    stop_all
    manager.image_registry.free allocation_
    // TODO(kasper): Check in the other methods before using this?
    allocation_ = null

abstract class ContainersServiceDefinition extends ServiceDefinition
    implements ContainersService:
  constructor:
    super ContainersService.NAME
        --major=ContainersService.MAJOR
        --minor=ContainersService.MINOR
    install

  handle client/int index/int arguments/any -> any:
    if index == ContainersService.LIST_IMAGES_INDEX:
      return list_images
    if index == ContainersService.START_IMAGE_INDEX:
      return start_image (uuid.Uuid arguments)
    if index == ContainersService.UNINSTALL_IMAGE_INDEX:
      return uninstall_image (uuid.Uuid arguments)
    if index == ContainersService.IMAGE_WRITER_OPEN_INDEX:
      return image_writer_open client arguments
    if index == ContainersService.IMAGE_WRITER_WRITE_INDEX:
      return image_writer_write client arguments[0] arguments[1]
    if index == ContainersService.IMAGE_WRITER_COMMIT_INDEX:
      return (image_writer_commit client arguments).to_byte_array
    if index == ContainersService.IMAGE_WRITER_CLOSE_INDEX:
      return image_writer_close client arguments
    unreachable

  abstract image_registry -> FlashRegistry
  abstract images -> List
  abstract add_flash_image allocation/FlashAllocation -> ContainerImage
  abstract lookup_image id/uuid.Uuid -> ContainerImage?

  abstract register_descriptor client/int descriptor/Object -> int
  abstract lookup_descriptor client/int handle/int -> any
  abstract unregister_descriptor client/int handle/int -> none

  list_images -> List:
    return images.map --in_place: | image/ContainerImage |
      image.id.to_byte_array

  start_image id/uuid.Uuid -> int?:
    image/ContainerImage? := lookup_image id
    if not image: return null
    return image.start.id

  uninstall_image id/uuid.Uuid -> none:
    image/ContainerImage? := lookup_image id
    if not image: return
    image.delete

  image_writer_open size/int -> int:
    unreachable  // <-- TODO(kasper): Nasty.

  image_writer_write handle/int bytes/ByteArray -> none:
    unreachable  // <-- TODO(kasper): Nasty.

  image_writer_commit handle/int -> uuid.Uuid:
    unreachable  // <-- TODO(kasper): Nasty.

  image_writer_close handle/int -> none:
    unreachable  // <-- TODO(kasper): Nasty.

  image_writer_open client/int size/int -> int?:
    relocated_size := size - (size / IMAGE_CHUNK_SIZE) * IMAGE_WORD_SIZE
    reservation := image_registry.reserve relocated_size
    if reservation == null: throw "FIXME: kasper"
    writer := ContainerImageWriter reservation
    return register_descriptor client writer

  image_writer_write client/int handle/int bytes/ByteArray -> none:
    writer := lookup_descriptor client handle
    writer.write bytes

  image_writer_commit client/int handle/int -> uuid.Uuid:
    writer := lookup_descriptor client handle
    image := add_flash_image writer.commit
    return image.id

  image_writer_close client/int handle/int -> none:
    writer := lookup_descriptor client handle
    unregister_descriptor client handle
    writer.close

class ContainerManager extends ContainersServiceDefinition implements SystemMessageHandler_:
  image_registry/FlashRegistry ::= ?
  service_manager_/SystemServiceManager ::= ?

  images_/Map ::= {:}               // Map<uuid.Uuid, ContainerImage>
  containers_by_id_/Map ::= {:}     // Map<int, Container>
  containers_by_image_/Map ::= {:}  // Map<uuid.Uuid, Container>
  next_handle_/int := 0
  done_ ::= monitor.Latch

  constructor .image_registry .service_manager_:
    set_system_message_handler_ SYSTEM_TERMINATED_ this
    set_system_message_handler_ SYSTEM_SPAWNED_ this
    set_system_message_handler_ SYSTEM_MIRROR_MESSAGE_ this
    image_registry.do: | allocation/FlashAllocation |
      if allocation.type != FLASH_ALLOCATION_PROGRAM_TYPE: continue.do
      add_flash_image allocation

  images -> List:
    return images_.values

  lookup_image id/uuid.Uuid -> ContainerImage?:
    return images_.get id

  register_image image/ContainerImage -> none:
    images_[image.id] = image

  lookup_container id/int -> Container?:
    return containers_by_id_.get id

  // TODO(kasper): Get rid of this slow implementation. The descriptor
  // handling will be done purely on the pids going forward.
  gid_from_pid_ pid/int-> int:
    containers_by_id_.do --values: | container/Container |
      if container.pids_.contains pid: return container.id
    unreachable

  lookup_descriptor pid/int handle/int -> Object?:
    gid := gid_from_pid_ pid
    container := containers_by_id_.get gid --if_absent=: return null
    descriptors := container.pids_.get pid --if_absent=: return null
    return descriptors.get handle

  register_descriptor pid/int descriptor/Object -> int:
    gid := gid_from_pid_ pid
    container := containers_by_id_[gid]
    descriptors := container.pids_[pid]
    handle := next_handle_++
    descriptors[handle] = descriptor
    return handle

  unregister_descriptor pid/int handle/int -> none:
    gid := gid_from_pid_ pid
    container := containers_by_id_.get gid --if_absent=: return
    descriptors := container.pids_.get pid --if_absent=: return
    descriptors.remove handle

  add_flash_image allocation/FlashAllocation -> ContainerImage:
    image := ContainerImageFlash this allocation
    register_image image
    return image

  // TODO(kasper): Not so happy with this name.
  wait_until_done -> int:
    if containers_by_id_.is_empty: return 0
    return done_.get

  // TODO(kasper): Not the prettiest interface.
  terminate error/int -> none:
    done_.set error

  on_container_start_ container/Container -> none:
    containers/Map ::= containers_by_image_.get container.image.id --init=: {:}
    containers[container.id] = container
    containers_by_id_[container.id] = container

  on_container_stop_ container/Container -> none:
    containers_by_id_.remove container.id
    if containers_by_id_.is_empty: done_.set 0

  on_image_stop_all_ image/ContainerImage -> none:
    containers/Map? ::= containers_by_image_.get image.id
    containers_by_image_.remove image.id
    if containers:
      containers.do: | id/int container/Container |
        container.on_stop_

  on_message type/int gid/int pid/int arguments/any -> none:
    container/Container? := lookup_container gid
    if type == SYSTEM_TERMINATED_:
      service_manager_.on_process_stop pid
      if container:
        error/int := arguments
        if error == 0: container.on_process_stop_ pid
        else: container.on_process_error_ pid error
    else if type == SYSTEM_SPAWNED_:
      if container: container.on_process_start_ pid
    else if type == SYSTEM_MIRROR_MESSAGE_:
      if not (container and container.image.trace arguments):
        print_for_manually_decoding_ arguments
    else:
      unreachable

print_for_manually_decoding_ message/ByteArray --from=0 --to=message.size:
  // Print a message on output so that that you can easily decode.
  // The message is base64 encoded to limit the output size.
  print_ "----"
  print_ "Received a Toit system message. Executing the command below will"
  print_ "make it human readable:"
  print_ "----"
  // Block size must be a multiple of 3 for this to work, due to the 3/4 nature
  // of base64 encoding.
  BLOCK_SIZE := 1500
  for i := from; i < to; i += BLOCK_SIZE:
    end := i >= to - BLOCK_SIZE
    prefix := i == from ? "build/host/sdk/bin/toit.run tools/system_message.toit build/snapshot -b " : ""
    base64_text := base64.encode (message.copy i (end ? to : i + BLOCK_SIZE))
    postfix := end ? "" : "\\"
    print_ "$prefix$base64_text$postfix"

// ----------------------------------------------------------------------------

container_spawn_ offset size gid -> int:
  #primitive.programs_registry.spawn

container_is_running_ offset size -> bool:
  #primitive.programs_registry.is_running

container_kill_flash_image_ offset size -> bool:
  #primitive.programs_registry.kill

container_next_gid_ -> int:
  #primitive.programs_registry.next_group_id

container_kill_pid_ pid/int -> bool:
  #primitive.core.signal_kill
