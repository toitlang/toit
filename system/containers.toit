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

import system.services show ServiceDefinition ServiceResource
import system.api.containers show ContainerService

import .flash.allocation
import .flash.image_writer
import .flash.registry
import .services

class Container:
  image/ContainerImage ::= ?
  gid_/int ::= ?
  pids_/Set ::= ?  // Set<int>

  constructor .image .gid_ pid/int:
    pids_ = { pid }

  id -> int:
    return gid_

  is_process_running pid/int -> bool:
    return pids_.contains pid

  on_stop_ -> none:
    pids_.do: on_process_stop_ it

  on_process_start_ pid/int -> none:
    assert: not pids_.is_empty
    pids_.add pid

  on_process_stop_ pid/int -> none:
    pids_.remove pid
    if pids_.is_empty: image.manager.on_container_stop_ this

  on_process_error_ pid/int error/int -> none:
    on_process_stop_ pid
    pids_.do: container_kill_pid_ it
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
    // TODO(kasper): We clear the allocation field, so maybe we should check for
    // null in the methods that use the field?
    allocation := allocation_
    allocation_ = null
    try:
      manager.unregister_image allocation.id
    finally:
      manager.image_registry.free allocation

abstract class ContainerServiceDefinition extends ServiceDefinition
    implements ContainerService:
  constructor:
    super "system/containers" --major=0 --minor=2
    provides ContainerService.UUID ContainerService.MAJOR ContainerService.MINOR
    install

  handle pid/int client/int index/int arguments/any -> any:
    if index == ContainerService.LIST_IMAGES_INDEX:
      return list_images
    if index == ContainerService.START_IMAGE_INDEX:
      return start_image (uuid.Uuid arguments)
    if index == ContainerService.UNINSTALL_IMAGE_INDEX:
      return uninstall_image (uuid.Uuid arguments)
    if index == ContainerService.IMAGE_WRITER_OPEN_INDEX:
      return image_writer_open client arguments
    if index == ContainerService.IMAGE_WRITER_WRITE_INDEX:
      writer ::= (resource client arguments[0]) as ContainerImageWriter
      return image_writer_write writer arguments[1]
    if index == ContainerService.IMAGE_WRITER_COMMIT_INDEX:
      writer ::= (resource client arguments) as ContainerImageWriter
      return (image_writer_commit writer).to_byte_array
    unreachable

  abstract image_registry -> FlashRegistry
  abstract images -> List
  abstract add_flash_image allocation/FlashAllocation -> ContainerImage
  abstract lookup_image id/uuid.Uuid -> ContainerImage?

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

  image_writer_open client/int size/int -> ServiceResource:
    relocated_size := size - (size / IMAGE_CHUNK_SIZE) * IMAGE_WORD_SIZE
    reservation := image_registry.reserve relocated_size
    if reservation == null: throw "No space left in flash"
    return ContainerImageWriter this client reservation

  image_writer_write writer/ContainerImageWriter bytes/ByteArray -> none:
    writer.write bytes

  image_writer_commit writer/ContainerImageWriter -> uuid.Uuid:
    image := add_flash_image writer.commit
    return image.id

class ContainerManager extends ContainerServiceDefinition implements SystemMessageHandler_:
  image_registry/FlashRegistry ::= ?
  service_manager_/SystemServiceManager ::= ?

  images_/Map ::= {:}               // Map<uuid.Uuid, ContainerImage>
  containers_by_id_/Map ::= {:}     // Map<int, Container>
  containers_by_image_/Map ::= {:}  // Map<uuid.Uuid, Container>

  system_image_/ContainerImage? := null
  done_ ::= monitor.Latch

  constructor .image_registry .service_manager_:
    set_system_message_handler_ SYSTEM_TERMINATED_ this
    set_system_message_handler_ SYSTEM_SPAWNED_ this
    set_system_message_handler_ SYSTEM_MIRROR_MESSAGE_ this

    image_registry.do: | allocation/FlashAllocation |
      if allocation.type != FLASH_ALLOCATION_PROGRAM_TYPE: continue.do
      add_flash_image allocation

    // Run through the bundled images in the VM, but skip the
    // first one which is always the system image.
    builtins := container_list_bundled_
    for i := 2; i < builtins.size; i += 2:
      allocation := FlashAllocation builtins[i]
      if not images_.contains allocation.id: add_flash_image allocation

  system_image -> ContainerImage:
    return system_image_

  images -> List:
    return images_.values.filter: it != system_image_

  lookup_image id/uuid.Uuid -> ContainerImage?:
    return images_.get id

  register_image image/ContainerImage -> none:
    images_[image.id] = image

  register_system_image image/ContainerImage -> none:
    register_image image
    system_image_ = image

  unregister_image id/uuid.Uuid -> none:
    images_.remove id

  lookup_container id/int -> Container?:
    return containers_by_id_.get id

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
    // TODO(kasper): We are supposed to always have a running system process. Maybe
    // we can generalize this handling and support background processes that do not
    // restrict us from exiting?
    remaining ::= containers_by_id_.size
    if remaining <= 1: done_.set 0

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
      origin_id/uuid.Uuid? ::= find_trace_origin_id arguments
      origin/ContainerImage? ::= origin_id and lookup_image origin_id
      if not (origin and origin.trace arguments):
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
    prefix := i == from ? "build/host/sdk/bin/toit.run tools/system_message.toit \"\$SNAPSHOT\" -b " : ""
    base64_text := base64.encode message[i..(end ? to : i + BLOCK_SIZE)]
    postfix := end ? "" : "\\"
    print_ "$prefix$base64_text$postfix"

find_trace_origin_id trace/ByteArray -> uuid.Uuid?:
  // Short strings are encoded with a single unsigned byte length ('U').
  skip_string ::= : | p |
    if trace[p] != 'S' or trace[p + 1] != 'U': return null
    p + trace[p + 2] + 3

  catch --no-trace:
    // The trace is a ubjson encoded array with 5 elements. The first entry
    // is an integer encoding of the 'X' character.
    if trace[0..6] != #['[', '#', 'U', 5, 'U', 'X']: return null
    // The next two entries are short version strings.
    position := skip_string.call 6
    position = skip_string.call position
    // The fourth entry is the byte array for the program id.
    if trace[position..position + 6] != #['[', '$', 'U', '#', 'U', 16]: return null
    return uuid.Uuid trace[position + 6..position + 22]
  return null

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

container_list_bundled_ -> Array_:
  #primitive.programs_registry.list_bundled
