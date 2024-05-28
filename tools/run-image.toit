// Copyright (C) 2024 Toitware ApS.
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

import ar
import crypto.sha256
import host.file
import host.directory
import io

import system.base.firmware show FirmwareServiceProviderBase FirmwareWriter
import system.containers
import system.services

import encoding.hex
import encoding.ubjson
import uuid

import .run-image-exit-codes
import ..system.boot
import ..system.containers
import ..system.flash.registry
import ..system.initialize
import ..system.storage
// TODO(florian) we should make this network-provider implementation more widely available.
import ..system.extensions.host.network show NetworkServiceProvider

RUN-IMAGE-FILE-NAME_ ::= "run-image"
CONFIG-FILE-NAME_ ::= "config.ubjson"
BITS-FILE-NAME_ ::= "bits.bin"
STARTUP-DIR-NAME ::= "startup-images"
BUNDLED-DIR-NAME ::= "bundled-images"
INSTALLED-DIR-NAME ::= "installed-images"
VALIDATED-FILE-NAME_ ::= "validated"

// TODO(kasper): It feels annoying to have to put this here. Maybe we
// can have some sort of reasonable default in the ContainerManager?
class SystemImage extends ContainerImage:
  id ::= containers.current

  constructor manager/ContainerManager:
    super manager

  spawn container/Container arguments/any -> int:
    // This container is already running as the system process.
    return Process.current.id

  stop-all -> none:
    unreachable  // Not implemented yet.

  delete -> none:
    unreachable  // Not implemented yet.

class FirmwareServiceProvider extends FirmwareServiceProviderBase:
  config_/Map ::= {:}
  config-ubjson_/ByteArray ::= #[]
  ota-dir-active_/string?
  ota-dir-inactive_/string?

  constructor --ota-dir-active/string? --ota-dir-inactive/string?:
    catch:
      config-ubjson_ = file.read-content "$ota-dir-active/$CONFIG-FILE-NAME_"
      config_ = ubjson.decode config-ubjson_
    ota-dir-active_ = ota-dir-active
    ota-dir-inactive_ = ota-dir-inactive
    super "system/firmware/host" --major=0 --minor=1

  is-validation-pending -> bool:
    return not file.is-file "$ota-dir-active_/$VALIDATED-FILE-NAME_"

  is-rollback-possible -> bool:
    return is-validation-pending

  validate -> bool:
    file.write-content --path="$ota-dir-active_/$VALIDATED-FILE-NAME_" #[]
    return true

  rollback -> none:
    if file.is-file "$ota-dir-active_/$VALIDATED-FILE-NAME_":
      throw "Can't rollback after validation"
    // By exiting without validating the outer script will automatically rollback.
    exit EXIT-CODE-ROLLBACK-REQUESTED

  upgrade -> none:
    if not ota-dir-inactive_: throw "No OTA directory"
    // Exit and tell the outer script that an update is available.
    exit EXIT-CODE-UPGRADE

  config-ubjson -> ByteArray:
    // We have to copy this for now, because we don't want to
    // risk getting our version of it neutered.
    return config-ubjson_.copy

  config-entry key/string -> any:
    return config_.get key

  content -> ByteArray:
    if not ota-dir-active_: throw "No OTA directory"
    return file.read-content "$ota-dir-active_/$BITS-FILE-NAME_"

  uri -> string?:
    return null

  firmware-writer-open client/int from/int to/int -> FirmwareWriter:
    if not ota-dir-inactive_: throw "No OTA directory"
    return FirmwareWriter_ this client from to --ota-dir-inactive=ota-dir-inactive_

class FirmwareWriter_ extends services.ServiceResource implements FirmwareWriter:
  image/ByteArray := #[]
  view_/ByteArray? := null
  cursor_/int := 0
  ota-dir-inactive_/string

  constructor provider/FirmwareServiceProvider client/int from/int to/int --ota-dir-inactive/string:
    ota-dir-inactive_ = ota-dir-inactive
    if to > image.size:
      // Grow the static image to the size this writer works on.
      // Replace the 0s with some value to avoid accidental use of uninitialized memory.
      image += ByteArray (to - image.size): it & 0xff
    view_ = image[from..to]
    super provider client

  write bytes/ByteArray from=0 to=bytes.size -> none:
    view_.replace cursor_ bytes[from..to]
    cursor_ += to - from

  pad size/int value/int -> none:
    to := cursor_ + size
    view_.fill --from=cursor_ --to=to value
    cursor_ = to

  flush -> int:
    // Everything is already flushed.
    return 0

  commit checksum/ByteArray? -> none:
    sha := sha256.Sha256
    sha.add image[..image.size - 32]
    actual := sha.get
    expected := image[image.size - 32..]
    if actual != expected:
      throw "Checksum mismatch"
    (Firmware image).write-into --dir=ota-dir-inactive_
    view_ = null

  on-closed -> none:
    if not view_: return
    view_ = null

class Firmware:
  static PART-HEADER_ ::= 0
  static PART-RUN-IMAGE_ ::= 1
  static PART-CONFIG_ ::= 2
  static PART-NAME-TO-UUID-MAPPING_ ::= 3
  static PART-STARTUP-IMAGES_ ::= 4
  static PART-BUNDLED-IMAGES_ ::= 5

  bits_/ByteArray

  constructor .bits_:

  part_ part-id/int -> ByteArray:
    from := 0
    for i := 0; i < part-id; i++:
      part-size := io.LITTLE-ENDIAN.int32 bits_ (i * 4)
      from += part-size
    size := io.LITTLE-ENDIAN.int32 bits_ (part-id * 4)
    to := from + size
    return bits_[from..to]

  run-image -> ByteArray:
    return part_ PART-RUN-IMAGE_

  config -> ByteArray:
    return part_ PART-CONFIG_

  name-to-uuid-mapping -> Map:
    return ubjson.decode (part_ PART-NAME-TO-UUID-MAPPING_)

  startup-images -> Map:
    return read-images_ (part_ PART-STARTUP-IMAGES_)

  bundled-images -> Map:
    return read-images_ (part_ PART-BUNDLED-IMAGES_)

  read-images_ part/ByteArray -> Map:
    result := {:}
    if part.is-empty: return result
    reader := ar.ArReader (io.Reader part)
    while file/ar.ArFile? := reader.next:
      result[file.name] = file.content
    return result

  write-into --dir/string:
    run-image-path := "$dir/$RUN-IMAGE-FILE-NAME_"
    file.write-content --path=run-image-path run-image
    file.chmod run-image-path 0b111_000_000  // Make the program executable.
    file.write-content --path="$dir/$CONFIG-FILE-NAME_" config
    startup-dir := "$dir/$STARTUP-DIR-NAME"
    directory.mkdir --recursive startup-dir
    mapping := name-to-uuid-mapping
    startup-images.do: | name/string content/ByteArray |
      uuid := mapping[name]
      file.write-content --path="$startup-dir/$uuid" content
    bundled-dir := "$dir/$BUNDLED-DIR-NAME"
    directory.mkdir --recursive bundled-dir
    bundled-images.do: | name string content/ByteArray |
      uuid := mapping[name]
      file.write-content --path="$bundled-dir/$uuid" content

main arguments:
  if arguments.size != 1 and arguments.size != 2:
    print_ "Usage:"
    print_ "  run-image image"
    print_ "  run-image dir-ota-active dir-ota-inactive"
    exit 1

  ota-active := null
  ota-inactive := null
  if arguments.size == 2:
    ota-active = arguments[0]
    ota-inactive = arguments[1]
    if not file.is-directory ota-active:
      print_ "Invalid argument: $ota-active"
      exit 1
    if not file.is-directory ota-inactive:
      print_ "Invalid argument: $ota-inactive"
      exit 1

  registry ::= FlashRegistry.scan
  storage := StorageServiceProvider registry
  network := NetworkServiceProvider
  container-manager ::= initialize-system registry [
    FirmwareServiceProvider --ota-dir-active=ota-active --ota-dir-inactive=ota-inactive,
    storage,
    network,
  ]
  container-manager.register-system-image (SystemImage container-manager)

  handle-arguments arguments container-manager

  exit (boot container-manager)

add-image path/string existing-uuids/Set --run-boot/bool --run-critical/bool -> none:
  path = path.replace --all "\\" "/"
  last-separator := path.index-of --last "/"
  last-segment := path[last-separator + 1..]
  file-uuid/uuid.Uuid? := uuid.parse last-segment --on-error=: null

  if file-uuid and existing-uuids.contains file-uuid:
    // Already in the flash.
    return

  image-data := file.read-content path
  writer := containers.ContainerImageWriter image-data.size
  writer.write image-data
  writer.commit --run-boot=run-boot --run-critical

handle-arguments arguments/List container-manager/ContainerManager -> none:
  existing-uuids/Set := {}
  container-manager.images.do: | image/ContainerImage |
    existing-uuids.add image.id

  if arguments.size == 1:
    image-path := arguments.first
    add-image image-path existing-uuids --run-boot --run-critical
    return

  assert: arguments.size == 2

  // We already checked that the second argument is a directory.
  active-dir := arguments.first
  if not file.is-directory active-dir:
    print_ "Invalid argument: $active-dir"
    exit 1

  // Assume the host-envelope directory structure. The directory
  // should contain:
  // config.ubjson
  // startup-images/
  // bundled-images/
  // installed-images/
  // The startup-images should be marked as "boot" and "critical".
  startup-dir := "$active-dir/$STARTUP-DIR-NAME"
  bundled-dir := "$active-dir/$BUNDLED-DIR-NAME"
  installed-dir := "$active-dir/$INSTALLED-DIR-NAME"

  [startup-dir, bundled-dir, installed-dir].do: | dir/string |
    is-startup-dir := dir == startup-dir
    // Directories are not required to be there.
    if not file.is-directory dir: continue.do
    stream := directory.DirectoryStream dir
    try:
      while file-name/string? := stream.next:
        path := "$dir/$file-name"
        if file.is-file path:
          add-image path existing-uuids --run-boot=is-startup-dir --run-critical=is-startup-dir
    finally:
      stream.close
