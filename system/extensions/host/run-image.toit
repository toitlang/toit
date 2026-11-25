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

import system.api.containers show ContainerService
import system.base.firmware show FirmwareServiceProviderBase FirmwareWriter
import system.containers
import system.services

import encoding.hex
import encoding.ubjson
import uuid show *

import .run-image-exit-codes
import .network show NetworkServiceProvider
import .storage
import ...boot
import ...containers
import ...flash.allocation
import ...flash.image-writer
import ...flash.registry
import ...flash.reservation
import ...storage
import ...services


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
      content := file.read-contents "$ota-dir-active/$CONFIG-FILE-NAME_"
      // TODO(kasper): We use an explicit Decoder to avoid barfing
      // on any padding that follows the encoded ubjson. This is
      // necessary for now, because for a while we didn't correctly
      // strip such padding before writing the config file to disk.
      decoder := ubjson.Decoder content
      config_ = decoder.decode
      config-ubjson_ = content[..decoder.offset_]
    ota-dir-active_ = ota-dir-active
    ota-dir-inactive_ = ota-dir-inactive
    super "system/firmware/host" --major=0 --minor=1

  is-validation-pending -> bool:
    return not file.is-file "$ota-dir-active_/$VALIDATED-FILE-NAME_"

  is-rollback-possible -> bool:
    return is-validation-pending

  validate -> bool:
    file.write-contents --path="$ota-dir-active_/$VALIDATED-FILE-NAME_" #[]
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
    return file.read-contents "$ota-dir-active_/$BITS-FILE-NAME_"

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
    config-part := part_ PART-CONFIG_
    config-size := io.LITTLE-ENDIAN.uint32 config-part 0
    return config-part[4 .. 4 + config-size]

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
      result[file.name] = file.contents
    return result

  write-into --dir/string:
    bits-path := "$dir/$BITS-FILE-NAME_"
    file.write-contents --path=bits-path bits_
    run-image-path := "$dir/$RUN-IMAGE-FILE-NAME_"
    file.write-contents --path=run-image-path run-image
    file.chmod run-image-path 0b111_101_000  // Make the program executable.
    file.write-contents --path="$dir/$CONFIG-FILE-NAME_" config
    startup-dir := "$dir/$STARTUP-DIR-NAME"
    directory.mkdir --recursive startup-dir
    mapping := name-to-uuid-mapping
    startup-images.do: | name/string content/ByteArray |
      uuid := mapping[name]
      file.write-contents --path="$startup-dir/$uuid" content
    bundled-dir := "$dir/$BUNDLED-DIR-NAME"
    directory.mkdir --recursive bundled-dir
    bundled-images.do: | name/string content/ByteArray |
      uuid := mapping[name]
      file.write-contents --path="$bundled-dir/$uuid" content

class RunImageContainerImageWriter extends ContainerImageWriter:
  container-manager_/RunImageContainerManager
  // Don't use the name "image_" as that one is used in the super class.
  relocatable-image/ByteArray? := ?
  offset_/int := 0

  constructor provider/RunImageContainerManager client/int reservation/FlashReservation:
    container-manager_ = provider
    // For each word in the image we need an additional bit.
    // It's easier to be conservative and assume we are on a 32-bit machine, than to
    // try to figure out the actual word size.
    // Divide by 4 to get the number of words. Then divide by 8 to get the relocation
    // bytes. Thus divide by 32 (>> 5) and then add one for rounding.
    relocatable-size := reservation.size + (reservation.size >> 5) + 1
    relocatable-image = ByteArray relocatable-size
    super provider client reservation

  // Override the default implementation.
  write data/ByteArray -> none:
    super data
    relocatable-image.replace offset_ data
    offset_ += data.size

  // Override the default implementation.
  commit --flags/int --data/int -> FlashAllocation:
    result := super --flags=flags --data=data
    container-manager_.on-committed-image_ result.id relocatable-image[..offset_]
        --flags=flags
        --data=data
    relocatable-image = null
    return result

class RunImageContainerManager extends ContainerManager:
  ota-dir-active_/string?
  save-to-fs_/bool := true

  constructor --ota-dir-active/string? image-registry/FlashRegistry service-manager/SystemServiceManager:
    ota-dir-active_ = ota-dir-active
    super image-registry service-manager

  // Override the default implementation.
  create-container-image-writer_ client/int reservation/FlashReservation -> ContainerImageWriter:
    if ota-dir-active_:
      return RunImageContainerImageWriter this client reservation
    return ContainerImageWriter this client reservation

  // Called from the image writer, with the bytes that were written (the
  // image with its shipped certificate) and the flags and data the image was
  // committed with.
  on-committed-image_ id/Uuid image/ByteArray --flags/int --data/int -> none:
    assert: ota-dir-active_ != null
    if not save-to-fs_: return
    dir := "$ota-dir-active_/$INSTALLED-DIR-NAME"
    directory.mkdir --recursive dir
    // The latest commit of an image determines how it runs (see
    // ContainerManager.register-image), so its backup replaces any older one.
    backup := InstalledImageBackup --image=image --flags=flags --data=data
    file.write-contents --path="$dir/$id" backup.encode

  // Override the default implementation.
  uninstall-image id/Uuid -> none:
    super id
    if not ota-dir-active_: return
    path := "$ota-dir-active_/$INSTALLED-DIR-NAME/$id"
    if file.is-file path: file.delete path

  /**
  Runs the given block but ensures that no committed image is saved to the
    file system.
  */
  without-fs-backup-do [block]:
    save-to-fs_ = false
    try:
      block.call
    finally:
      save-to-fs_ = true

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

  service-manager ::= SystemServiceManager
  // Install all the providers.
  firmware-service-provider := FirmwareServiceProvider
      --ota-dir-active=ota-active
      --ota-dir-inactive=ota-inactive
  firmware-service-provider.install
  (StorageServiceProviderHost registry).install
  (NetworkServiceProvider).install

  // Create the container manager.
  container-manager := RunImageContainerManager --ota-dir-active=ota-active registry service-manager
  system-image := SystemImage container-manager
  container-manager.register-system-image (SystemImage container-manager)

  handle-arguments arguments container-manager

  exit (boot container-manager)

/**
The backup of an image installed through the containers service.

A host's flash registry does not survive a restart: boot.sh deletes it
  after a crash, and a program allocation is only valid at the address
  the registry was mapped at (its checksum covers the address). So
  run-image keeps a backup of every installed image in the
  $INSTALLED-DIR-NAME directory of the active OTA directory, and
  reinstalls it at the next start through the containers service, like a
  fresh install.

A backup is $MAGIC_, the size of the metadata (4 bytes, little endian),
  the metadata (a UBJSON map with the "flags" and the "data" the image was
  committed with, and the "sha256" of the image), and the image, as it was
  written to the containers service. The image includes its shipped
  certificate, which the installer drops from the flash, so that an
  untrusted image is verified again when it is reinstalled. The backup
  has no verdict: the VM computes it again, from the bytes it installs.

Older builds wrote the image alone (the flags were lost). Such a backup
  doesn't show that its image was installed trusted, so it is reinstalled
  untrusted: it is verified and runs sandboxed, or is not installed. An
  image alone can't start with the magic: its first byte holds the
  relocation bits of the header's first words (the marker, the checksum,
  the id and the metadata), which are never relocated. And a backup with
  the magic is only taken if the digest of its image matches.
*/
class InstalledImageBackup:
  static MAGIC_ ::= #['T', 'I', 'I', 'B', 'A', 'K', '0', '1']

  image/ByteArray
  flags/int
  data/int
  /** Whether this backup was written by an older build, without metadata. */
  is-legacy/bool

  constructor --.image --.flags --.data --.is-legacy=false:

  /**
  Decodes the backup $bytes.

  A backup without $MAGIC_ is one of an older build: it is decoded as an
    untrusted image. Throws if the metadata of a backup with the magic
    can't be read or doesn't match its image.
  */
  static decode bytes/ByteArray -> InstalledImageBackup:
    if bytes.size < MAGIC_.size or bytes[..MAGIC_.size] != MAGIC_:
      return InstalledImageBackup
          --image=bytes
          --flags=ContainerService.FLAG-UNTRUSTED
          --data=0
          --is-legacy
    header-size := MAGIC_.size + 4
    if bytes.size < header-size: throw "CORRUPT_BACKUP"
    metadata-size := io.LITTLE-ENDIAN.uint32 bytes MAGIC_.size
    if metadata-size > bytes.size - header-size: throw "CORRUPT_BACKUP"
    metadata := null
    catch: metadata = ubjson.decode bytes[header-size..header-size + metadata-size]
    if metadata is not Map: throw "CORRUPT_BACKUP"
    flags-entry := metadata.get "flags"
    data-entry := metadata.get "data"
    sha-entry := metadata.get "sha256"
    if flags-entry is not int or not 0 <= flags-entry <= 0xff: throw "CORRUPT_BACKUP"
    if data-entry is not int or not 0 <= data-entry <= 0xffff_ffff: throw "CORRUPT_BACKUP"
    if sha-entry is not ByteArray: throw "CORRUPT_BACKUP"
    image := bytes[header-size + metadata-size..]
    if (sha256.sha256 image) != sha-entry: throw "CORRUPT_BACKUP"
    return InstalledImageBackup --image=image --flags=flags-entry --data=data-entry

  encode -> ByteArray:
    metadata := ubjson.encode {
      "flags": flags,
      "data": data,
      "sha256": sha256.sha256 image,
    }
    header := ByteArray MAGIC_.size + 4
    header.replace 0 MAGIC_
    io.LITTLE-ENDIAN.put-uint32 header MAGIC_.size metadata.size
    return header + metadata + image

/**
Whether the image in the file $path is already in the flash: its file name
  is one of the $existing-uuids.
*/
is-in-flash_ path/string existing-uuids/Set -> bool:
  path = path.replace --all "\\" "/"
  last-separator := path.index-of --last "/"
  last-segment := path[last-separator + 1..]
  file-uuid/Uuid? := Uuid.parse last-segment --if-error=: null
  return file-uuid != null and existing-uuids.contains file-uuid

add-image path/string existing-uuids/Set --run-boot/bool --run-critical/bool -> none:
  if is-in-flash_ path existing-uuids: return
  install-image_ (file.read-contents path) --run-boot=run-boot --run-critical=run-critical

/**
Installs the image $path of the firmware (from the startup-images or the
  bundled-images directory, see `extract-host` in tools/firmware.toit) with
  the flags the envelope gives the container, which are in the header of
  the image, as on a device. (Older builds installed every startup image,
  run-boot or run-critical, as both.) An image of the startup directory
  ($is-startup) without a readable header is installed run-boot and
  run-critical.
*/
add-firmware-image path/string existing-uuids/Set --is-startup/bool -> none:
  if is-in-flash_ path existing-uuids: return
  image := file.read-contents path
  flags := image-header-flags_ image
  if not flags:
    flags = is-startup ? ContainerService.FLAG-RUN-BOOT | ContainerService.FLAG-RUN-CRITICAL : 0
  install-image_ image
      --run-boot=(flags & ContainerService.FLAG-RUN-BOOT != 0)
      --run-critical=(flags & ContainerService.FLAG-RUN-CRITICAL != 0)
      // The envelope has no untrusted containers; a flagged header is
      // honored all the same (the image is verified).
      --untrusted=(flags & ContainerService.FLAG-UNTRUSTED != 0)

/**
The flags in the header of the relocatable $image (the metadata byte of
  `ImageHeader` in tools/firmware.toit), or null if it has no header.

A relocatable image starts with the relocation bits of its first chunk;
  the header follows.
*/
image-header-flags_ image/ByteArray -> int?:
  HEADER-MARKER ::= 0xdeadface
  METADATA-OFFSET ::= 24
  header := IMAGE-WORD-SIZE
  if image.size <= header + METADATA-OFFSET: return null
  if (io.LITTLE-ENDIAN.uint32 image header) != HEADER-MARKER: return null
  return image[header + METADATA-OFFSET]

/**
Reinstalls the image of the backup $path (see $InstalledImageBackup) with
  the flags and the data it was installed with.

A backup that can't be read or whose image is refused (for example by the
  verifier) is reported and left in place: it doesn't keep the system
  from starting, and uninstalling the image deletes it.
*/
add-installed-image path/string existing-uuids/Set -> none:
  if is-in-flash_ path existing-uuids: return
  exception := catch:
    backup := InstalledImageBackup.decode (file.read-contents path)
    if backup.is-legacy:
      print-on-stderr_ "Installed image $path has no metadata (older build): reinstalling it untrusted"
    // The other bits of the flags are not the installer's to give: the VM
    // sets the assets bit and the verdict bit at the commit.
    flags := backup.flags
    install-image_ backup.image
        --run-boot=(flags & ContainerService.FLAG-RUN-BOOT != 0)
        --run-critical=(flags & ContainerService.FLAG-RUN-CRITICAL != 0)
        --untrusted=(flags & ContainerService.FLAG-UNTRUSTED != 0)
        --data=backup.data
  if exception:
    print-on-stderr_ "Not reinstalling installed image $path: $exception"

install-image_ image-data/ByteArray
    --run-boot/bool
    --run-critical/bool
    --untrusted/bool=false
    --data/int=0 -> none:
  writer := containers.ContainerImageWriter image-data.size
  writer.write image-data
  writer.commit --run-boot=run-boot --run-critical=run-critical --untrusted=untrusted --data=data

handle-arguments arguments/List container-manager/RunImageContainerManager -> none:
  existing-uuids/Set := {}
  container-manager.images.do: | image/ContainerImage |
    existing-uuids.add image.id

  if arguments.size == 1:
    image-path := arguments.first
    container-manager.without-fs-backup-do:
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
  // The startup-images are the run-boot or run-critical containers of the
  // envelope; the flags of the startup and the bundled images are in their
  // headers (see $add-firmware-image).
  // The installed-images are backups (see $InstalledImageBackup).
  startup-dir := "$active-dir/$STARTUP-DIR-NAME"
  bundled-dir := "$active-dir/$BUNDLED-DIR-NAME"
  installed-dir := "$active-dir/$INSTALLED-DIR-NAME"

  container-manager.without-fs-backup-do:
    [startup-dir, bundled-dir, installed-dir].do: | dir/string |
      is-startup-dir := dir == startup-dir
      // Directories are not required to be there.
      if not file.is-directory dir: continue.do
      stream := directory.DirectoryStream dir
      try:
        while file-name/string? := stream.next:
          path := "$dir/$file-name"
          if not file.is-file path: continue
          if dir == installed-dir:
            add-installed-image path existing-uuids
          else:
            add-firmware-image path existing-uuids --is-startup=is-startup-dir
      finally:
        stream.close
