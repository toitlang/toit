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

import binary
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
  resources/Set ::= {}

  constructor .image .gid_ pid/int:
    pids_ = { pid }

  id -> int:
    return gid_

  is_process_running pid/int -> bool:
    return pids_.contains pid

  stop -> none:
    if pids_.is_empty: return
    pids_.do: container_kill_pid_ it
    pids_.clear
    image.manager.on_container_stop_ this 0
    resources.do: it.on_container_stop 0

  on_stop_ -> none:
    pids_.do: on_process_stop_ it 0

  on_process_start_ pid/int -> none:
    assert: not pids_.is_empty
    pids_.add pid

  on_process_stop_ pid/int error/int -> none:
    pids_.remove pid
    if error != 0:
      pids_.do: container_kill_pid_ it
      pids_.clear
    else if not pids_.is_empty:
      return
    image.manager.on_container_stop_ this error
    resources.do: it.on_container_stop error

class ContainerResource extends ServiceResource:
  container/Container
  hash_code/int ::= hash_code_next

  constructor .container service/ServiceDefinition client/int:
    super service client --notifiable
    container.resources.add this

  static hash_code_next_/int := 0
  static hash_code_next -> int:
    next := hash_code_next_
    hash_code_next_ = (next + 1) & 0x1fff_ffff
    return next

  on_container_stop code/int -> none:
    if is_closed: return
    notify_ code

  on_closed -> none:
    container.resources.remove this

abstract class ContainerImage:
  manager/ContainerManager ::= ?
  constructor .manager:

  abstract id -> uuid.Uuid

  start -> Container:
    return start default_arguments

  trace encoded/ByteArray -> bool:
    return false

  flags -> int:
    return 0

  data -> int:
    return 0

  run_boot -> bool:
    return flags & ContainerService.FLAG_RUN_BOOT != 0

  run_critical -> bool:
    return flags & ContainerService.FLAG_RUN_CRITICAL != 0

  default_arguments -> any:
    // TODO(kasper): For now, the default arguments passed
    // to a container on start is an empty list. We could
    // consider making it null instead.
    return []

  abstract start arguments/any -> Container
  abstract stop_all -> none
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
    return binary.LITTLE_ENDIAN.uint32 allocation_.metadata 1

  start arguments/any -> Container:
    gid ::= container_next_gid_
    pid ::= container_spawn_ allocation_.offset allocation_.size gid arguments
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
      return start_image client (uuid.Uuid arguments[0]) arguments[1]
    if index == ContainerService.STOP_CONTAINER_INDEX:
      resource ::= (resource client arguments) as ContainerResource
      return stop_container resource
    if index == ContainerService.UNINSTALL_IMAGE_INDEX:
      return uninstall_image (uuid.Uuid arguments)
    if index == ContainerService.IMAGE_WRITER_OPEN_INDEX:
      return image_writer_open client arguments
    if index == ContainerService.IMAGE_WRITER_WRITE_INDEX:
      writer ::= (resource client arguments[0]) as ContainerImageWriter
      return image_writer_write writer arguments[1]
    if index == ContainerService.IMAGE_WRITER_COMMIT_INDEX:
      writer ::= (resource client arguments[0]) as ContainerImageWriter
      return (image_writer_commit writer arguments[1] arguments[2]).to_byte_array
    unreachable

  abstract image_registry -> FlashRegistry
  abstract images -> List
  abstract add_flash_image allocation/FlashAllocation -> ContainerImage
  abstract lookup_image id/uuid.Uuid -> ContainerImage?

  list_images -> List:
    raw := images
    result := []
    raw.do: | image/ContainerImage |
      result.add image.id.to_byte_array
      result.add image.flags
      result.add image.data
    return result

  start_image id/uuid.Uuid arguments/any -> int:
    unreachable  // <-- TODO(kasper): Nasty.

  start_image client/int id/uuid.Uuid arguments/any -> ContainerResource?:
    image/ContainerImage? := lookup_image id
    if not image: return null
    return ContainerResource (image.start arguments) this client

  stop_container resource/ContainerResource? -> none:
    resource.container.stop

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

  image_writer_commit writer/ContainerImageWriter flags/int data/int -> uuid.Uuid:
    allocation := writer.commit --flags=flags --data=data
    image := add_flash_image allocation
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
    set_system_message_handler_ SYSTEM_TRACE_ this

    image_registry.do: | allocation/FlashAllocation |
      if allocation.type != FLASH_ALLOCATION_PROGRAM_TYPE: continue.do
      add_flash_image allocation

    // Run through the bundled images in the VM.
    bundled := container_bundled_images_
    for i := 0; i < bundled.size; i += 2:
      allocation := FlashAllocation bundled[i]
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

  on_container_start_ container/Container -> none:
    containers/Map ::= containers_by_image_.get container.image.id --init=: {:}
    containers[container.id] = container
    containers_by_id_[container.id] = container

  on_container_stop_ container/Container error/int -> none:
    containers_by_id_.remove container.id
    // If we've got an error in an image that run with the run.critical
    // flag, we treat that as a fatal error and terminate the system process.
    if error != 0 and container.image.run_critical:
      done_.set error
      return
    // TODO(kasper): We are supposed to always have a running system process. Maybe
    // we can generalize this handling and support background processes that do not
    // restrict us from exiting?
    remaining ::= containers_by_id_.size
    if remaining <= 1 and not done_.has_value: done_.set 0

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
        container.on_process_stop_ pid error
    else if type == SYSTEM_SPAWNED_:
      if container: container.on_process_start_ pid
    else if type == SYSTEM_TRACE_:
      origin_id/uuid.Uuid? ::= trace_find_origin_id arguments
      origin/ContainerImage? ::= origin_id and lookup_image origin_id
      if not (origin and origin.trace arguments):
        trace_using_print arguments
    else:
      unreachable

trace_using_print message/ByteArray --from=0 --to=message.size:
  // Print a trace message on output so that that you can easily decode.
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
    prefix := i == from ? "jag decode " : ""
    base64_text := base64.encode message[i..(end ? to : i + BLOCK_SIZE)]
    postfix := end ? "" : "\\"
    print_ "$prefix$base64_text$postfix"

trace_find_origin_id trace/ByteArray -> uuid.Uuid?:
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

container_spawn_ offset size gid arguments -> int:
  #primitive.programs_registry.spawn

container_is_running_ offset size -> bool:
  #primitive.programs_registry.is_running

container_kill_flash_image_ offset size -> bool:
  #primitive.programs_registry.kill

container_next_gid_ -> int:
  #primitive.programs_registry.next_group_id

container_kill_pid_ pid/int -> bool:
  #primitive.core.signal_kill

container_bundled_images_ -> Array_:
  #primitive.programs_registry.bundled_images
