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

import bitmap
import crypto.sha256 as crypto
import io
import io show LITTLE-ENDIAN
import system
import system show platform
import uuid show *

import encoding.json
import encoding.ubjson
import encoding.tison

import system.assets

import ar
import cli
import host.directory
import host.file
import host.os
import host.pipe
import partition-table show *
import tar

import ..system.extensions.host.run-image-boot-sh
import .image
import .snapshot
import .snapshot-to-image

ENVELOPE-FORMAT-VERSION ::= 8

WORD-SIZE-ESP32 ::= 4

// Shared AR entries.
AR-ENTRY-INFO       ::= "\$envelope"
AR-ENTRY-METADATA   ::= "\$metadata"
AR-ENTRY-PROPERTIES ::= "\$properties"

META-SDK-VERSION ::= "sdk-version"
META-WORD-SIZE   ::= "word-size"
META-KIND        ::= "kind"

// ESP32 AR entries.
AR-ENTRY-ESP32-FIRMWARE-BIN   ::= "\$firmware.bin"
AR-ENTRY-ESP32-FIRMWARE-ELF   ::= "\$firmware.elf"
AR-ENTRY-ESP32-BOOTLOADER-BIN ::= "\$bootloader.bin"
AR-ENTRY-ESP32-PARTITIONS-BIN ::= "\$partitions.bin"
AR-ENTRY-ESP32-OTADATA-BIN    ::= "\$otadata.bin"
AR-ENTRY-ESP32-FLASHING-JSON  ::= "\$flashing.json"

AR-ENTRY-ESP32-FILE-MAP ::= {
  "firmware.bin"    : AR-ENTRY-ESP32-FIRMWARE-BIN,
  "firmware.elf"    : AR-ENTRY-ESP32-FIRMWARE-ELF,
  "bootloader.bin"  : AR-ENTRY-ESP32-BOOTLOADER-BIN,
  "partitions.bin"  : AR-ENTRY-ESP32-PARTITIONS-BIN,
  "otadata.bin"     : AR-ENTRY-ESP32-OTADATA-BIN,
  "flashing.json"   : AR-ENTRY-ESP32-FLASHING-JSON,
}

// Host AR entries.
AR-ENTRY-HOST-RUN-IMAGE ::= "\$run-image"

SYSTEM-CONTAINER-NAME ::= "system"

OPTION-ENVELOPE     ::= "envelope"
OPTION-OUTPUT       ::= "output"
OPTION-OUTPUT-SHORT ::= "o"

PROPERTY-CONTAINER-FLAGS ::= "\$container-flags"

IMAGE-FLAG-RUN-BOOT     ::= 1 << 0
IMAGE-FLAG-RUN-CRITICAL ::= 1 << 1
IMAGE-FLAG-HAS-ASSETS   ::= 1 << 7

is-snapshot-bundle bits/ByteArray -> bool:
  catch: return SnapshotBundle.is-bundle-content bits
  return false

pad bits/ByteArray alignment/int -> ByteArray:
  size := bits.size
  padded-size := round-up size alignment
  return bits + (ByteArray padded-size - size)

read-file path/string --ui/cli.Ui -> ByteArray:
  exception := catch:
    return file.read-contents path
  ui.abort "Failed to open '$path' for reading ($exception)."
  unreachable

read-file path/string --ui/cli.Ui [block]:
  stream/file.Stream? := null
  exception := catch: stream = file.Stream.for-read path
  if not stream:
    ui.abort "Failed to open '$path' for reading ($exception)."
  try:
    block.call (io.Reader.adapt stream)
  finally:
    stream.close

write-file path/string --ui/cli.Ui [block] -> none:
  stream/file.Stream? := null
  exception := catch: stream = file.Stream.for-write path
  if not stream:
    ui.abort "Failed to open '$path' for writing ($exception)."
  try:
    writer := io.Writer.adapt stream
    block.call writer
  finally:
    stream.close

main arguments/List:
  firmware-cmd := build-command --create-esp32-only
  firmware-cmd.run arguments

build-command --create-esp32-only/bool=false -> cli.Command:
  firmware-cmd := cli.Command "firmware"
      --help="""
        Manipulate firmware envelopes.

        An envelope is an artifact that bundles native firmware images with Toit containers.
        This command can be used to create, inspect, extract, and manipulate envelopes.
        """
      --options=[
        cli.Option OPTION-ENVELOPE
            --short-name="e"
            --help="Set the envelope to work on."
            --type="file"
            --required
      ]
  if create-esp32-only:
    firmware-cmd.add (create-esp32-cmd --name="create")
  else:
    firmware-cmd.add create-cmd
  firmware-cmd.add extract-cmd
  firmware-cmd.add flash-cmd
  firmware-cmd.add container-cmd
  firmware-cmd.add property-cmd
  firmware-cmd.add show-cmd
  firmware-cmd.add tool-cmd
  return firmware-cmd

create-cmd -> cli.Command:
  options := AR-ENTRY-ESP32-FILE-MAP.map: | key/string value/string |
    cli.Option key
        --help="Set the $key part."
        --type="file"
        --required=(key == "firmware.bin")
  cmd := cli.Command "create"
      --help="""
        Create a firmware envelope of the specified kind.
        """
  cmd.add (create-esp32-cmd --name="esp32")
  cmd.add create-host-cmd
  return cmd

create-esp32-cmd --name/string -> cli.Command:
  options := AR-ENTRY-ESP32-FILE-MAP.map: | key/string value/string |
    cli.Option key
        --help="Set the $key part."
        --type="file"
        --required=(key == "firmware.bin")
  return cli.Command name
      --help="""
        Create a firmware envelope from a native firmware image.

        Add the Toit system snapshot to the envelope with the 'firmware.bin' option.
        """
      --options=options.values + [
        cli.Option "system.snapshot"
            --type="file"
            --required,
      ]
      --run=:: create-envelope-esp32 it

create-envelope-esp32 invocation/cli.Invocation -> none:
  output-path := invocation[OPTION-ENVELOPE]
  input-path := invocation["firmware.bin"]

  ui := invocation.cli.ui

  firmware-bin-data := read-file input-path --ui=ui
  binary := Esp32Binary firmware-bin-data
  binary.remove-drom-extension firmware-bin-data

  system-snapshot-content := read-file invocation["system.snapshot"] --ui=ui
  system-snapshot := SnapshotBundle system-snapshot-content

  entries := {
    AR-ENTRY-ESP32-FIRMWARE-BIN: binary.bits,
    SYSTEM-CONTAINER-NAME: system-snapshot-content,
    AR-ENTRY-PROPERTIES: json.encode {
      PROPERTY-CONTAINER-FLAGS: {
        SYSTEM-CONTAINER-NAME: IMAGE-FLAG-RUN-BOOT | IMAGE-FLAG-RUN-CRITICAL
      }
    }
  }

  AR-ENTRY-ESP32-FILE-MAP.do: | key/string value/string |
    if key == "firmware.bin": continue.do
    filename := invocation.parameters[key]
    if filename: entries[value] = read-file filename --ui=ui

  envelope := Envelope.create entries
      --sdk-version=system-snapshot.sdk-version
      --kind=Envelope.KIND-ESP32
      --word-size=WORD-SIZE-ESP32
  envelope.store output-path --ui=ui

create-host-cmd -> cli.Command:
  return cli.Command "host"
      --help="""
        Create a firmware envelope for the host system.
        """
      --options=[
        cli.Option "run-image"
            --help="Path to the run-image executable."
            --type="file"
            --required,
        cli.OptionInt "word-size"
            --required,
      ]
      --run=:: create-envelope-host it

create-envelope-host invocation/cli.Invocation -> none:
  output-path := invocation[OPTION-ENVELOPE]

  word-size := invocation["word-size"]
  run-image-path := invocation["run-image"]

  ui := invocation.cli.ui
  run-image-bytes := read-file run-image-path --ui=ui

  entries := {
    AR-ENTRY-HOST-RUN-IMAGE: run-image-bytes,
  }

  // TODO(florian): we are using the sdk-version of the firmware-tool.
  // That's almost always correct, but we should verify that the
  // run-image has the same version.
  envelope := Envelope.create entries
      --sdk-version=system.app-sdk-version
      --kind=Envelope.KIND-HOST
      --word-size=word-size
  envelope.store output-path --ui=ui

container-cmd -> cli.Command:
  cmd := cli.Command "container"
      --help="Manipulate Toit containers in a firmware envelope."
  option-output := cli.Option OPTION-OUTPUT
      --short-name=OPTION-OUTPUT-SHORT
      --help="Set the output envelope."
      --type="file"
  option-name := cli.Option "name"
      --type="string"
      --required

  cmd.add
      cli.Command "install"
          --help="Add a container to the envelope."
          --aliases=["add"]
          --options=[
            option-output,
            cli.Option "assets"
                --help="Add assets to the container."
                --type="file",
            cli.OptionEnum "trigger" ["none", "boot"]
                --help="Trigger the container to run automatically."
                --default="boot",
            cli.Flag "critical"
                --help="Reboot system if the container terminates.",
          ]
          --rest=[
            option-name,
            cli.Option "image"
                --type="file"
                --required
          ]
          --run=:: container-install it

  cmd.add
      cli.Command "extract"
          --help="Extract a container from the envelope."
          --options=[
            cli.Option "output"
                --help="Set the output file name."
                --short-name="o"
                --required,
            cli.OptionEnum "part" ["image", "assets"]
                --help="Pick the part of the container to extract."
                --required
          ]
          --rest=[option-name]
          --run=:: container-extract it

  cmd.add
      cli.Command "uninstall"
          --help="Remove a container from the envelope."
          --aliases=["remove"]
          --options=[ option-output ]
          --rest=[ option-name ]
          --run=:: container-uninstall it

  cmd.add
      cli.Command "list"
          --help="""
            List the containers in the envelope.

            If no output file is given or the output is '-', the list is printed to stdout.
            When printed to a file, the list is in JSON format.
            """
          --options=[
            cli.Option "output"
                --help="Set the output file name."
                --short-name="o",
          ]
          --run=:: container-list it

  return cmd

read-assets path/string? --ui/cli.Ui -> ByteArray?:
  if not path: return null
  data := read-file path --ui=ui
  // Try decoding the assets to verify that they
  // have the right structure.
  exception := catch:
    assets.decode data
    return data
  ui.abort "Failed to decode the assets in '$path'."
  unreachable

decode-image data/ByteArray --word-size/int -> ImageHeader:
  out := io.Buffer
  output := BinaryRelocatedOutput out 0x12345678 --word-size=word-size
  output.write data
  decoded := out.bytes
  return ImageHeader decoded --word-size=word-size

get-container-name invocation/cli.Invocation -> string:
  ui := invocation.cli.ui
  name := invocation["name"]
  if name.starts-with "\$" or name.starts-with "+":
    ui.abort "Cannot install container with a name that starts with \$ or +."
  if name.size == 0:
    ui.abort "Cannot install container with an empty name."
  if name.size > 14:
    ui.abort "Cannot install container with a name longer than 14 characters."
  return name

is-system-name name/string -> bool:
  // Normally names should have at least a character, but to avoid
  // out-of-bound errors we allow empty names here.
  return name.size == 0 or name[0] == '$'

is-container-name name/string -> bool:
  if not 0 < name.size <= 14: return false
  first := name[0]
  return first != '$' and first != '+'

container-install invocation/cli.Invocation -> none:
  ui := invocation.cli.ui
  name := get-container-name invocation
  image-path := invocation["image"]
  assets-path := invocation["assets"]
  image-data := read-file image-path --ui=ui
  assets-data := read-assets assets-path --ui=ui
  is-snapshot := is-snapshot-bundle image-data

  update-envelope invocation: | envelope/Envelope |
    if is-snapshot:
      bundle := SnapshotBundle name image-data
      if bundle.sdk-version != envelope.sdk-version:
        ui.abort "Snapshot was built by SDK $bundle.sdk-version, but envelope is for SDK $envelope.sdk-version."
    else:
      header := null
      catch: header = decode-image image-data --word-size=envelope.word-size
      if not header:
        ui.abort "Input is not a valid snapshot or image ('$image-path')."
      expected-system-uuid := sdk-version-uuid --sdk-version=envelope.sdk-version
      if header.system-uuid != expected-system-uuid:
        ui.emit --error "Image cannot be verified to have been built by SDK $envelope.sdk-version."
        ui.emit --error "Image is for $header.system-uuid, but envelope is $expected-system-uuid."
        ui.abort

    envelope.entries[name] = image-data
    if assets-data: envelope.entries["+$name"] = assets-data
    else: envelope.entries.remove "+$name"

    flag-bits := 0
    if invocation["trigger"] == "boot": flag-bits |= IMAGE-FLAG-RUN-BOOT
    if invocation["critical"]: flag-bits |= IMAGE-FLAG-RUN-CRITICAL
    properties-update envelope: | properties/Map? |
      properties = properties or {:}
      flags := properties.get PROPERTY-CONTAINER-FLAGS --init=: {:}
      flags[name] = flag-bits
      properties

container-extract invocation/cli.Invocation -> none:
  input-path := invocation[OPTION-ENVELOPE]
  ui := invocation.cli.ui
  name := get-container-name invocation
  entries := (Envelope.load input-path --ui=ui).entries
  part := invocation["part"]
  key := (part == "assets") ? "+$name" : name
  if not entries.contains key:
    invocation.cli.ui.abort "Container '$name' has no $part."
  entry := entries[key]
  write-file invocation["output"] --ui=ui: it.write entry

container-uninstall invocation/cli.Invocation -> none:
  name := get-container-name invocation
  update-envelope invocation: | envelope/Envelope |
    envelope.entries.remove name
    envelope.entries.remove "+$name"

    properties-update envelope: | properties/Map? |
      flags := properties and properties.get PROPERTY-CONTAINER-FLAGS
      if flags: flags.remove name
      properties

container-list invocation/cli.Invocation -> none:
  ui := invocation.cli.ui

  output-path := invocation[OPTION-OUTPUT]
  input-path := invocation[OPTION-ENVELOPE]
  envelope := Envelope.load input-path --ui=ui
  entries := envelope.entries

  entries-json := build-entries-json entries --word-size=envelope.word-size
  output := entries-json["containers"]

  if output-path:
    file.write-contents --path=output-path (json.encode output)
    return

  output-string := ""
  if ui.wants-human:
    output-string = json-to-human output: | chain/List |
      chain.size != 1
    ui.emit --result output-string
  else:
    ui.emit-map --result
        --title="Containers"
        output

build-entries-json entries/Map --word-size/int -> Map:
  properties/Map? := entries.get AR-ENTRY-PROPERTIES
      --if-present=: json.decode it
  flags := properties and properties.get PROPERTY-CONTAINER-FLAGS
  containers := {:}
  entries.do: | name/string content/ByteArray |
    if not is-container-name name: continue.do
    assets := entries.get "+$name"
    entry := extract-container name flags content --assets=assets --word-size=word-size
    map := {
      "kind": (is-snapshot-bundle content) ? "snapshot" : "image",
      "id"  : entry.id.to-string,
      "size": content.size,
    }
    if assets:
      map["assets"] = { "size": assets.size }
    if entry.flags != 0:
      flag-names := []
      if (entry.flags & IMAGE-FLAG-RUN-BOOT) != 0:
        flag-names.add "trigger=boot"
      if (entry.flags & IMAGE-FLAG-RUN-CRITICAL) != 0:
        flag-names.add "critical"
      map["flags"] = flag-names
    containers[name] = map
  other-entries := {:}
  entries.do: | name/string content/ByteArray |
    if not is-system-name name: continue.do
    other-entries[name[1..]] = {
      "size": content.size,
    }
  return {
    "containers": containers,
    "entries": other-entries,
  }

property-cmd -> cli.Command:
  cmd := cli.Command "property"
      --help="Manipulate properties in a firmware envelope."

  option-output := cli.Option OPTION-OUTPUT
      --short-name=OPTION-OUTPUT-SHORT
      --help="Set the output envelope."
      --type="file"
  option-key := cli.Option "key"
      --type="string"
  option-key-required := cli.Option option-key.name
      --type=option-key.type
      --required

  cmd.add
      cli.Command "get"
          --rest=[ cli.Option "key" --type="string" ]
          --run=:: property-get it

  cmd.add
      cli.Command "remove"
          --options=[ option-output ]
          --rest=[ option-key-required ]
          --run=:: property-remove it

  cmd.add
      cli.Command "set"
          --options=[ option-output ]
          --rest=[ option-key-required, cli.Option "value" --multi --required ]
          --run=:: property-set it

  return cmd

property-get invocation/cli.Invocation -> none:
  input-path := invocation[OPTION-ENVELOPE]
  key := invocation["key"]

  ui := invocation.cli.ui

  envelope := Envelope.load input-path --ui=ui
  if key == "sdk-version":
    ui.emit --result envelope.sdk-version
    return

  entries := envelope.entries
  entry := entries.get AR-ENTRY-PROPERTIES
  if not entry: return

  properties := json.decode entry
  result := null
  if key:
    if properties.contains key:
      result = properties.get key
  else:
    filtered := properties.filter: not it.starts-with "\$"
    ui.emit --result (json.stringify filtered)
  if result != null:
    if ui.wants-structured:
      ui.emit --result result
    else:
      ui.emit --result (json.stringify result)

property-remove invocation/cli.Invocation -> none:
  properties-update-with-key invocation: | properties/Map? key/string |
    if properties: properties.remove key
    properties

property-set invocation/cli.Invocation -> none:
  value := invocation["value"].map:
    // Try to parse this as a JSON value, but treat it
    // as a string if it fails.
    element := it
    catch: element = json.parse element
    element
  if value.size == 1: value = value.first
  properties-update-with-key invocation: | properties/Map? key/string |
    if key == "uuid":
      exception := catch: Uuid.parse value
      if exception: throw "cannot parse uuid: $value ($exception)"
    properties = properties or {:}
    properties[key] = value
    properties

properties-update envelope/Envelope [block] -> none:
  properties/Map? := envelope.entries.get AR-ENTRY-PROPERTIES
      --if-present=: json.decode it
  properties = block.call properties
  if properties: envelope.entries[AR-ENTRY-PROPERTIES] = json.encode properties

properties-update-with-key invocation/cli.Invocation [block] -> none:
  key/string := invocation["key"]
  if key.starts-with "\$": throw "property keys cannot start with \$"
  if key == "sdk-version": throw "cannot update sdk-version property"
  update-envelope invocation: | envelope/Envelope |
    properties-update envelope: | properties/Map? |
      block.call properties key

extract-cmd -> cli.Command:
  return cli.Command "extract"
      --help="""
        Extracts the firmware image of the envelope to a file.

        The following formats are supported:
        For ESP32:
        - binary: the binary app partition. To use with 'esptool',
          you must specify the correct memory offset for the partition.
        - elf: the ELF file of the executable. This is typically used
          for debugging.
        - ubjson: a UBJSON encoding of the sections of the image.
        - image: the complete flash image (bootloader, partitions, and app).
          Can be flashed to address 0x0 using 'esptool', or run on QEMU/Wokwi.
        - qemu: a deprecated alias for 'image'.
        For host:
        - tar: a tar ball with a bash script to run the extracted firmware.
        - binary: the binary image of the firmware, which can be used for
          firmware upgrades.
        - ubjson: a UBJSON encoding suitable for incremental updates.

        The '--partition-table' and '--partition' option can only be used
        for ESP32 envelopes with format 'image'. The '--partition-table'
        replaces the partition table that is in the envelope, and the
        '--partition' option replaces partitions or adds custom partitions
        to the image. See the 'flash' command for more details.

        # QEMU
        It is recommended to use the `esp32-qemu` firmware, since it includes an
        ethernet driver that is compatible with QEMU.

        The generated image (say 'output.bin') can be run with the
        following command:

            qemu-system-xtensa \\
                -M esp32 \\
                -nographic \\
                -drive file=output.bin,format=raw,if=mtd \\
                -nic user,model=open_eth,hostfwd=tcp::2222-:1234 \\
                -s

        The '-nic' option is optional. In this example, the local port 2222 is
        forwarded to port 1234 in the QEMU image.

        # Wokwi
        After extracting the binary image, open the Wokwi editor and
        press F1. Then type "Upload firmware and start simulation".

        # Flashing
        You can flash a binary image to the ESP32 using the `esptool` tool.
        ```
        esptool.py write_flash 0 output.bin
        ```
        """
      --options=[
        cli.Option OPTION-OUTPUT
            --short-name=OPTION-OUTPUT-SHORT
            --help="Set the output file."
            --type="file"
            --required,
        cli.Option "config"
            --type="file",
        cli.OptionEnum "format" ["binary", "elf", "ubjson", "image", "qemu", "tar"]
            --help="Set the output format."
            --default="binary",
        cli.Option "partitions"
            --help="Override the partition table of the envelope."
            --type="file",
        cli.OptionPatterns "partition"
            ["file:<name>=<path>", "empty:<name>=<size>"]
            --help="Replace the content of a partition or add a custom partition to the flashed image."
            --split-commas
            --multi,
      ]
      --run=:: extract it

extract invocation/cli.Invocation -> none:
  ui := invocation.cli.ui

  input-path := invocation[OPTION-ENVELOPE]
  envelope := Envelope.load input-path --ui=ui

  config-path := invocation["config"]

  partition-table-path/string? := invocation["partitions"]
  partitions-args/List := invocation["partition"]
  if partition-table-path or not partitions-args.is-empty:
    if envelope.kind != Envelope.KIND-ESP32:
      ui.abort "The '--partition-table' and '--partition' options can only be used for ESP32 envelopes."
    if invocation["format"] != "image":
      ui.abort "The '--partition-table' and '--partition' options can only be used with the 'image' format."

  config-encoded := ByteArray 0
  if config-path:
    config-encoded = read-file config-path --ui=ui
    exception := catch: ubjson.decode config-encoded
    if exception: config-encoded = ubjson.encode (json.decode config-encoded)

  if envelope.kind == Envelope.KIND-ESP32:
    extract-esp32 invocation envelope --config-encoded=config-encoded
  else if envelope.kind == Envelope.KIND-HOST:
    extract-host invocation envelope --config-encoded=config-encoded
  else:
    throw "unsupported kind: $(envelope.kind)"

extract-esp32 -> none
    invocation/cli.Invocation
    envelope/Envelope
    --config-encoded/ByteArray:
  output-path := invocation[OPTION-OUTPUT]

  ui := invocation.cli.ui

  format := invocation["format"]
  if format == "tar":
    throw "unsupported format for ESP32 envelope: '$format'"

  if format == "elf":
    if not config-encoded.is-empty:
      ui.emit --warning "Config is ignored when extracting elf file."
    write-file output-path --ui=ui: it.write (envelope.entries.get AR-ENTRY-ESP32-FIRMWARE-ELF)
    return

  if format == "qemu" or format == "image":
    if format == "qemu":
      ui.emit --warning "The 'qemu' format is deprecated, use 'image' instead."
    build-esp32-image invocation envelope
        --config-encoded=config-encoded
        --write=: | partitions _ flashing |
          write-partitions_ output-path partitions --flashing=flashing --ui=ui
    return

  firmware-bin := extract-binary-esp32 envelope --config-encoded=config-encoded

  if format == "binary":
    write-file output-path --ui=ui: it.write firmware-bin
    return

  if not format == "ubjson":
    throw "unknown format: $(format)"

  binary := Esp32Binary firmware-bin
  parts := binary.parts firmware-bin
  output := {
    "parts"   : parts,
    "binary"  : firmware-bin,
  }
  write-file output-path --ui=ui: it.write (ubjson.encode output)

extract-host invocation/cli.Invocation envelope/Envelope --config-encoded/ByteArray:
  word-size := envelope.word-size
  output-path := invocation[OPTION-OUTPUT]
  system-uuid := sdk-version-uuid --sdk-version=envelope.sdk-version

  format := invocation["format"]
  if format != "tar" and format != "binary" and format != "ubjson":
    throw "unsupported format for host envelope: '$format'"

  ui := invocation.cli.ui
  entries := envelope.entries
  flags := get-flags envelope
  run-image := entries.get AR-ENTRY-HOST-RUN-IMAGE
  startup-images := {:}
  bundled-images := {:}
  name-to-uuid-mapping := {:}
  entries.do: | name/string content/ByteArray |
    if not is-container-name name: continue.do
    entry-assets := entries.get "+$name"
    container := extract-container name flags content --assets=entry-assets --word-size=word-size
    uuid := container.id.to-string
    relocated := container.relocate
        --relocation-base=0 // Must be 0, since we add the relocation information back.
        --system-uuid=system-uuid
        --attach-assets
    // The image needs to be padded to page-size.
    relocated = pad relocated (1 << 12)
    relocatable := container.relocation-information.apply-to relocated
    if container.flags & IMAGE-FLAG-RUN-BOOT != 0 or container.flags & IMAGE-FLAG-RUN-CRITICAL != 0:
      startup-images[name] = relocatable
    else:
      bundled-images[name] = relocatable
    name-to-uuid-mapping[name] = uuid

  parts := []
  bits := io.Buffer

  // Reserve space for the header.
  header-size := 6 * 4
  bits.grow-by header-size
  parts.add { "type": "header", "from": 0, "to": header-size }

  part-start := bits.size
  bits.write run-image
  parts.add { "type": "run-image", "from": part-start, "to": bits.size }

  part-start = bits.size
  config-buffer := io.Buffer
  // Add the size to have a similar layout to the ESP32 binary.
  config-buffer.little-endian.write-uint32 config-encoded.size
  config-buffer.write config-encoded
  // Pad the config to 4 KB. This makes it less likely that the header (which includes
  // the config-part size) changes for different configurations.
  config-buffer.pad --alignment=(4 * 1024)
  bits.write config-buffer.bytes
  parts.add { "type": "config", "from": part-start, "to": bits.size }

  part-start = bits.size
  bits.write (ubjson.encode name-to-uuid-mapping)
  parts.add { "type": "name-to-uuid-mapping", "from": part-start, "to": bits.size }

  part-start = bits.size
  ar-writer := ar.ArWriter bits
  startup-images.do: | uuid/string image/ByteArray |
    ar-writer.add uuid image
  parts.add { "type": "startup-images", "from": part-start, "to": bits.size }

  part-start = bits.size
  ar-writer = ar.ArWriter bits
  bundled-images.do: | uuid/string image/ByteArray |
    ar-writer.add uuid image
  parts.add { "type": "bundled-images", "from": part-start, "to": bits.size }

  // Update the header with the parts offsets before computing the checksum.
  bits-le := bits.little-endian
  header-offset := 0
  parts.do: | part |
    bits-le.put-int32 --at=header-offset (part["to"] - part["from"])
    header-offset += 4
  if header-offset != header-size:
    throw "header size mismatch"

  part-start = bits.size
  checksum := crypto.sha256 bits.bytes
  bits.write checksum
  parts.add { "type": "checksum", "from": part-start, "to": bits.size }

  bits.close

  if format == "binary":
    write-file output-path --ui=ui: it.write bits.bytes
    return

  ubjson-data := {
    "parts": parts,
    "binary": bits.bytes,
  }
  encoded-ubjson := ubjson.encode ubjson-data
  if format == "ubjson":
    write-file output-path --ui=ui: it.write encoded-ubjson
    return

  assert: format == "tar"

  EXECUTABLE-PERMISSIONS := 0b111_101_000

  // For the "tar" output create a tarball.
  tar-bytes := io.Buffer
  tar-writer := tar.Tar tar-bytes
  tar-writer.add "boot.sh" BOOT-SH --permissions=EXECUTABLE-PERMISSIONS
  tar-writer.add "ota0/validated" ""
  tar-writer.add "ota0/run-image" run-image --permissions=EXECUTABLE-PERMISSIONS
  tar-writer.add "ota0/bits.bin" bits.bytes
  tar-writer.add "ota0/config.ubjson" config-encoded
  startup-images.do: | name/string image/ByteArray |
    uuid := name-to-uuid-mapping[name]
    tar-writer.add "ota0/startup-images/$uuid" image
  bundled-images.do: | name/string image/ByteArray |
    uuid := name-to-uuid-mapping[name]
    tar-writer.add "ota0/bundled-images/$uuid" image
  tar-writer.close --close-writer

  write-file output-path --ui=ui: it.write tar-bytes.bytes

write-partitions_ output-path/string partitions/Map --flashing/Map --ui/cli.Ui:
  flash-size-string := flashing["flash_settings"]["flash_size"]
  if not flash-size-string.ends-with "MB":
    ui.abort "Unexpected flash size '$flash-size-string'."
  flash-size := (int.parse flash-size-string[..flash-size-string.size - 2]) * 1024 * 1024

  out-image := ByteArray flash-size
  partitions.do: | offset/int content/ByteArray |
    out-image.replace offset content
  write-file output-path --ui=ui: it.write out-image

build-esp32-image invocation/cli.Invocation envelope/Envelope --config-encoded/ByteArray [--write] -> none:
  cli := invocation.cli
  ui := cli.ui

  partition-table-path := invocation["partitions"]

  firmware-bin := extract-binary-esp32 envelope --config-encoded=config-encoded
  binary := Esp32Binary firmware-bin
  flashing := envelope.entries.get AR-ENTRY-ESP32-FLASHING-JSON
      --if-present=: json.decode it
      --if-absent=: ui.abort "Envelope is missing a 'flashing.json' entry."

  partition-table-bytes := partition-table-path
      ? read-file partition-table-path --ui=ui
      : envelope.entries.get AR-ENTRY-ESP32-PARTITIONS-BIN
  partition-table := PartitionTable.decode partition-table-bytes

  // Map the file:<name>=<path> and empty:<name>=<size> partitions
  // to entries in the partition table by allocating at the end
  // of the used part of the flash image.
  partitions := {:}
  parsed-partitions := invocation["partition"]
  parsed-partitions.do: | entry/Map |
    description := ?
    is-file := entry.contains "file"
    if is-file: description = entry["file"]
    else: description = entry["empty"]
    assign-index := description.index-of "="
    if assign-index < 0: ui.abort "Malformed partition description '$description'."
    name := description[..assign-index]
    if not (0 < name.size <= 15): ui.abort "Malformed partition name '$name'."
    if partitions.contains name: ui.abort "Duplicate partition named '$name'."
    value := description[assign-index + 1..]
    partition-content/ByteArray := ?
    if is-file:
      partition-content = read-file value --ui=ui
    else:
      size := int.parse value --if-error=:
        ui.abort "Malformed partition size '$value'."
      partition-content = ByteArray size
    partition-content = pad partition-content 4096

    existing-partition := partition-table.find --name=name
    if existing-partition:
      if existing-partition.size < partition-content.size:
        ui.abort "Partition '$name' is too big to fit in designated partition ($partition-content.size > $existing-partition.size)."
      partitions[existing-partition.offset] = partition-content
    else:
      offset := partition-table.find-first-free-offset
      partition := Partition
          --name=name
          --type=0x41
          --subtype=0
          --offset=partition-table.find-first-free-offset
          --size=partition-content.size
          --flags=0
      partitions[offset] = partition-content
      partition-table.add partition

  // The bootloader partition is not part of the partition-table.
  bootloader-bin := envelope.entries.get AR-ENTRY-ESP32-BOOTLOADER-BIN
  bootloader-offset := int.parse flashing["bootloader"]["offset"][2..] --radix=16
  partitions[bootloader-offset] = bootloader-bin

  // The partition-table partition is not part of the partition-table.
  partitions-bin := partition-table.encode
  partitions-offset := int.parse flashing["partition-table"]["offset"][2..] --radix=16
  partitions[partitions-offset] = partitions-bin

  otadata-partition := partition-table.find-otadata
  otadata-partition-offset := otadata-partition.offset
  otadata-bin := envelope.entries.get AR-ENTRY-ESP32-OTADATA-BIN
  partitions[otadata-partition-offset] = otadata-bin

  app-partition := partition-table.find-app  // Typically called ota_0.
  app-partition-offset := app-partition.offset
  if firmware-bin.size > app-partition.size:
    ui.abort "Firmware is too big to fit in designated partition ($firmware-bin.size > $app-partition.size)"
  partitions[app-partition-offset] = firmware-bin

  chip := binary.chip-name
  write.call partitions chip flashing

find-esptool_ -> List:
  bin-extension := ?
  bin-name := system.program-path
  if platform == system.PLATFORM-WINDOWS:
    bin-name = bin-name.replace --all "\\" "/"
    bin-extension = ".exe"
  else:
    bin-extension = ""

  if esptool-path := os.env.get "ESPTOOL_PATH":
    if esptool-path.ends-with ".py":
      return ["python3$bin-extension", esptool-path]
    return [esptool-path]

  if jag-toit-repo-path := os.env.get "JAG_TOIT_REPO_PATH":
    return [
      "python3$bin-extension",
      "$jag-toit-repo-path/third_party/esp-idf/components/esptool_py/esptool/esptool.py"
    ]

  list := bin-name.split "/"
  dir := list[..list.size - 1].join "/"
  if bin-name.ends-with ".toit":
    if dir == "": dir = "."
    esptool-py := "$dir/../third_party/esp-idf/components/esptool_py/esptool/esptool.py"
    if file.is-file esptool-py:
      return ["python3$bin-extension", esptool-py]
  else if dir != "":
    // This executable is supposed to live in 'bin', whereas the esptool is in 'lib/toit/bin'.
    esptool := "$dir/../lib/toit/bin/esptool$bin-extension"
    if file.is-file esptool:
      return [esptool]
  // Try to find esptool in PATH.
  esptool := "esptool$bin-extension"
  catch:
    pipe.backticks esptool "version"
    // Succeeded, so just return it.
    return [esptool]
  // An exception was thrown.
  // Try to find esptool.py in PATH.
  if system.platform != system.PLATFORM-WINDOWS:
    exit-value := pipe.system "esptool.py version > /dev/null 2>&1"
    if exit-value == 0:
      location := pipe.backticks "/bin/sh" "-c" "command -v esptool.py"
      return ["python3", location.trim]
  throw "cannot find esptool"

tool-cmd -> cli.Command:
  return cli.Command "tool"
      --help="Provides information about used external tools."
      --subcommands=[
        esptool-cmd,
      ]

esptool-cmd -> cli.Command:
  return cli.Command "esptool"
      --aliases=["esp-tool", "esp_tool"]
      --help="Prints the path and version of the found esptool."
      --examples=[
        cli.Example "Print the path and version of the found esptool."
            --arguments="-e ignored-envelope"
      ]
      --run=:: esptool it

esptool invocation/cli.Invocation -> none:
  ui := invocation.cli.ui
  esptool := find-esptool_
  command := esptool.join " "
  version := pipe.backticks (esptool + ["version"])

  if ui.wants-structured:
    ui.emit --result {"command": esptool, "version": version}
  else if ui.wants-human:
    ui.emit --result "Command: $esptool\nVersion: $version"
  else:
    ui.emit --result "$command\n$version"

flash-cmd -> cli.Command:
  return cli.Command "flash"
      --help="""
          Flash a firmware envelope to a device.

          The partition table is extracted from the envelope unless the
          '--partitions' option is used.

          The '--partition' option can be used to replace the content of existing
          partitions or to add custom partitions to the flashed image. If a
          partition with the given name exists, its content is replaced with the
          provided data. Otherwise, the partition is added on top of the partitions
          that are specified in the (potentially overridden) partition table.
          Newly added partitions are of type 0x41, subtype 0, and have no flags.

          Uses Espressif's esptool.py to flash the image. Use
          'ESPTOOL_PATH' to specify the path to the esptool.py script if you don't
          want to use the bundled version.
          """
      --options=[
        cli.Option "config"
            --type="file",
        cli.Option "port"
            --type="file"
            --short-name="p"
            --required,
        cli.OptionInt "baud"
            --default=921600,
        cli.OptionEnum "chip" ["esp32", "esp32c3", "esp32c6", "esp32s2", "esp32s3"]
            --hidden
            --help="Deprecated. Don't use this option.",
        cli.OptionPatterns "partition"
            ["file:<name>=<path>", "empty:<name>=<size>"]
            --help="Replace the content of a partition or add a custom partition to the flashed image."
            --split-commas
            --multi,
        cli.Option "partitions"
            --help="Override the partition table."
            --type="file",
      ]
      --run=:: flash it

flash invocation/cli.Invocation -> none:
  input-path := invocation[OPTION-ENVELOPE]
  config-path := invocation["config"]
  port := invocation["port"]
  baud := invocation["baud"]
  partition-table-path := invocation["partitions"]

  ui := invocation.cli.ui

  if invocation["chip"]:
    ui.emit --warning "The 'chip' option is deprecated and should not be used."

  envelope := Envelope.load input-path --ui=ui

  if envelope.kind != Envelope.KIND-ESP32:
    ui.abort "Only ESP32 envelopes can be flashed."

  if platform != system.PLATFORM-WINDOWS:
    stat := file.stat port
    if not stat or stat[file.ST-TYPE] != file.CHARACTER-DEVICE:
      throw "cannot open port '$port'"

  config-encoded := ByteArray 0
  if config-path:
    config-encoded = read-file config-path --ui=ui
    exception := catch: ubjson.decode config-encoded
    if exception: config-encoded = ubjson.encode (json.decode config-encoded)

  build-esp32-image invocation envelope --config-encoded=config-encoded
      --write=: | partitions/Map chip/string flashing/Map |
        tmp := directory.mkdtemp "/tmp/toit-flash-"
        try:
          partition-args := []
          partitions.do: | offset/int contents/ByteArray |
            tmp-file := "$tmp/partition-$offset"
            write-file tmp-file --ui=ui: it.write contents
            partition-args.add "0x$(%x offset)"
            partition-args.add tmp-file

          esptool := find-esptool_

          // The new esptool has deprecated underscores in some arguments.
          // TODO(floitsch): remove these replacements when the esp-idf has been updated
          //   to a version that uses the new arguments.
          before-args := flashing["extra_esptool_args"]["before"]
          after-args := flashing["extra_esptool_args"]["after"]
          write-flash-args := flashing["write_flash_args"]
          before-args = before-args.replace --all "default_reset" "default-reset"
          before-args = before-args.replace --all "no_reset" "no-reset"
          after-args = after-args.replace --all "hard_reset" "hard-reset"
          after-args = after-args.replace --all "no_reset" "no-reset"
          write-flash-args.map --in-place:
            if it == "--flash_mode": "--flash-mode"
            else if it == "--flash_size": "--flash-size"
            else if it == "--flash_freq": "--flash-freq"
            else: it

          code := pipe.run-program esptool + [
            "--port", port,
            "--baud", "$baud",
            "--chip", chip,
            "--before", before-args,
            "--after", after-args
          ] + [ "write-flash" ] + write-flash-args + partition-args
          if code != 0: exit 1
        finally:
          directory.rmdir --recursive tmp

get-flags envelope/Envelope -> Map?:
  properties := envelope.entries.get AR-ENTRY-PROPERTIES
      --if-present=: json.decode it
  return properties and properties.get PROPERTY-CONTAINER-FLAGS

extract-binary-esp32 envelope/Envelope --config-encoded/ByteArray -> ByteArray:
  containers ::= []
  entries := envelope.entries
  properties := entries.get AR-ENTRY-PROPERTIES
      --if-present=: json.decode it
      --if-absent=: {:}
  flags := get-flags envelope

  // The system image, if any, must be the first image, so
  // we reserve space for it in the list of containers.
  has-system-image := entries.contains SYSTEM-CONTAINER-NAME
  if has-system-image: containers.add null

  // Compute relocatable images for all the non-system containers.
  non-system-images := {:}
  entries.do: | name/string content/ByteArray |
    if name == SYSTEM-CONTAINER-NAME or not is-container-name name:
      continue.do  // Skip.
    assets := entries.get "+$name"
    entry := extract-container name flags content --assets=assets --word-size=envelope.word-size
    containers.add entry
    non-system-images[name] = entry.id.to-byte-array

  if has-system-image:
    name := SYSTEM-CONTAINER-NAME
    content := entries[name]
    // TODO(kasper): Take any other system assets into account.
    system-assets := {:}
    // Encode any WiFi information.
    properties.get "wifi" --if-present=: system-assets["wifi"] = tison.encode it
    // Encode any non-system image names.
    if not non-system-images.is-empty: system-assets["images"] = tison.encode non-system-images
    // Encode the system assets and add them to the container.
    assets-encoded := assets.encode system-assets
    containers[0] = extract-container name flags content --assets=assets-encoded --word-size=envelope.word-size

  firmware-bin := entries.get AR-ENTRY-ESP32-FIRMWARE-BIN
  if not firmware-bin:
    throw "cannot find $AR-ENTRY-ESP32-FIRMWARE-BIN entry in envelope '$envelope.path'"

  system-uuid/Uuid? := null
  if properties.contains "uuid":
    system-uuid = Uuid.parse properties["uuid"] --if-error=(: null)
  system-uuid = system-uuid or sdk-version-uuid --sdk-version=envelope.sdk-version

  return extract-binary-content
      --binary-input=firmware-bin
      --containers=containers
      --system-uuid=system-uuid
      --config-encoded=config-encoded

extract-container -> ContainerEntry
    name/string flags/Map? content/ByteArray --word-size/int --assets/ByteArray?:
  header/ImageHeader := ?
  relocatable/ByteArray := ?
  if is-snapshot-bundle content:
    snapshot-bundle := SnapshotBundle name content
    snapshot-uuid ::= snapshot-bundle.uuid
    program := snapshot-bundle.decode
    image := build-image program word-size
        --system-uuid=Uuid.NIL
        --snapshot-uuid=snapshot-uuid
        --assets=assets
    header = ImageHeader image.all-memory --word-size=word-size
    if header.snapshot-uuid != snapshot-uuid: throw "corrupt snapshot uuid encoding"
    relocatable = image.build-relocatable
  else:
    header = decode-image content --word-size=word-size
    relocatable = content
  flag-bits := flags and flags.get name
  flag-bits = flag-bits or 0
  return ContainerEntry header.id name relocatable --flags=flag-bits --assets=assets --word-size=word-size

update-envelope invocation/cli.Invocation [block] -> none:
  input-path := invocation[OPTION-ENVELOPE]
  output-path := invocation[OPTION-OUTPUT]
  if not output-path: output-path = input-path

  ui := invocation.cli.ui

  existing := Envelope.load input-path --ui=ui
  block.call existing

  envelope := Envelope.create existing.entries
      --sdk-version=existing.sdk-version
      --kind=existing.kind
      --word-size=existing.word-size
  envelope.store output-path --ui=ui

extract-binary-content -> ByteArray
    --binary-input/ByteArray
    --containers/List
    --system-uuid/Uuid
    --config-encoded/ByteArray:
  binary := Esp32Binary binary-input
  image-count := containers.size
  image-table := ByteArray 8 * image-count

  table-address := binary.extend-drom-address
  relocation-base := table-address + 5 * 4 + image-table.size
  images := []
  index := 0
  containers.do: | container/ContainerEntry |
    image-size := container.relocated-size

    LITTLE-ENDIAN.put-uint32 image-table index * 8
        relocation-base
    LITTLE-ENDIAN.put-uint32 image-table index * 8 + 4
        image-size
    image-bits := container.relocate
        --relocation-base=relocation-base
        --system-uuid=system-uuid
        --attach-assets
    images.add image-bits
    relocation-base += image-bits.size
    index++

  // Build the DROM extension by adding a header in front of the
  // table entries. The header will be patched later when we know
  // the total sizes.
  extension-header := ByteArray 5 * 4
  LITTLE-ENDIAN.put-uint32 extension-header (0 * 4) 0x98dfc301
  LITTLE-ENDIAN.put-uint32 extension-header (3 * 4) image-count
  extension := extension-header + image-table
  images.do: extension += it

  // Now add the device-specific configurations at the end.
  used-size := extension.size
  config-size := ByteArray 4
  LITTLE-ENDIAN.put-uint32 config-size 0 config-encoded.size
  extension += config-size
  extension += config-encoded

  // If the encoded config is small, we make sure to reserve
  // more space so the config area is guaranteed to be useful
  // for slightly larger configs without changing the free
  // size in the header. Usually, the padding we do after this
  // is more than enough, but we want a guarantee to have some
  // space available.
  reserved := 1024 - config-encoded.size
  if reserved > 0: extension += ByteArray reserved

  // This is a pretty serious padding up. We do it to guarantee
  // that segments that follow this one do not change their
  // alignment within the individual flash pages, which seems
  // to be a requirement. It might be possible to get away with
  // less padding somehow.
  extension = pad extension 64 * 1024
  free-size := extension.size - used-size

  // Update the extension header.
  checksum := 0xb3147ee9
  LITTLE-ENDIAN.put-uint32 extension (1 * 4) used-size
  LITTLE-ENDIAN.put-uint32 extension (2 * 4) free-size
  4.repeat: checksum ^= LITTLE-ENDIAN.uint32 extension (it * 4)
  LITTLE-ENDIAN.put-uint32 extension (4 * 4) checksum

  binary.patch-extend-drom system-uuid table-address extension
  return binary.bits

show-cmd -> cli.Command:
  return cli.Command "show"
      --help="Show the contents of the given firmware envelope."
      --options=[
        cli.OptionEnum "output-format" ["human", "json"]
            --default="human",
        cli.Flag "all"
            --help="Show all information, including non-container entries."
            --short-name="a",
        cli.Option "output"
            --help="Write output to the given file."
            --short-name="o",
      ]
      --run=:: show it

show invocation/cli.Invocation -> none:
  input-path := invocation[OPTION-ENVELOPE]
  output-path := invocation["output"]
  output-format := invocation["output-format"]
  show-all := invocation["all"]

  ui := invocation.cli.ui

  envelope := Envelope.load input-path --ui=ui
  kind-string := envelope.kind == Envelope.KIND-ESP32
      ? Envelope.KIND-STRING-ESP32
      : Envelope.KIND-STRING-HOST

  result := {
    "envelope-format-version": envelope.version_,
    "kind": kind-string,
    "sdk-version": envelope.sdk-version,
  }

  if envelope.kind == Envelope.KIND-ESP32:
    firmware-bin := extract-binary-esp32 envelope --config-encoded=#[]
    binary := Esp32Binary firmware-bin
    result["chip"] = binary.chip-name

  // Add the containers after the chip name for esthetical reasons.
  entries-json := build-entries-json envelope.entries --word-size=envelope.word-size
  result["containers"] = entries-json["containers"]

  if show-all:
    result["entries"] = entries-json["entries"]

  if output-path:
    write-file output-path --ui=ui: it.write (json.encode result)
    return

  output := ""
  if ui.wants-human:
    output = json-to-human result: | chain/List |
      chain.size != 2 or (chain[0] != "containers" and chain[0] != "entries")
    ui.emit --result output
  else:
    ui.emit-map --result result

capitalize_ str/string -> string:
  if str == "": return ""
  return str[..1].to-ascii-upper + str[1..]

humanize-key_ key/string -> string:
  parts := key.split "-"
  parts.map --in-place: it == "sdk" ? "SDK" : it
  parts[0] = capitalize_ parts[0]
  return parts.join " "

json-to-human o/any --indentation/int=0 --skip-indentation/bool=false --chain/List=[] [should-humanize] -> string:
  result := ""
  if o is Map:
    o.do: | key/string value |
      new-chain := chain + [key]
      human-key := (should-humanize.call new-chain) ? (humanize-key_ key) : key
      if not skip-indentation:
        result += " " * indentation
      else:
        skip-indentation = false
      result += "$human-key: "
      if value is not Map and value is not List:
        result += "$value\n"
      else:
        result += "\n"
        result += json-to-human value --indentation=(indentation + 2) --chain=new-chain should-humanize
  else if o is List:
    o.do: | value |
      if not skip-indentation:
        result += " " * indentation
      else:
        skip-indentation = false
      result += "-"
      if value is Map:
        result += " "
        result += json-to-human value --indentation=(indentation + 2) --skip-indentation --chain=chain should-humanize
      else if value is List:
        result += "\n"
        result += json-to-human value --indentation=(indentation + 2) --chain=chain should-humanize
      else:
        result += " $value\n"
  else:
    if not skip-indentation:
      result += " " * indentation
    else:
      skip-indentation = false
    result += "$o\n"

  return result

class Envelope:
  static MARKER ::= 0x0abeca70

  static KIND-ESP32 ::= 0
  static KIND-HOST  ::= 1

  static KIND-STRING-ESP32 ::= "esp32"
  static KIND-STRING-HOST  ::= "host"

  static INFO-ENTRY-MARKER-OFFSET   ::= 0
  static INFO-ENTRY-VERSION-OFFSET  ::= 4
  static INFO-ENTRY-SIZE            ::= 8

  version_/int

  path/string? ::= null
  sdk-version/string
  kind/int
  word-size/int
  entries/Map ::= {:}

  constructor.load .path/string --ui/cli.Ui:
    version_ = -1
    sdk-version = ""
    kind = -1
    word-size = -1
    read-file path --ui=ui: | reader/io.Reader |
      ar := ar.ArReader reader
      while file := ar.next:
        if file.name == AR-ENTRY-INFO:
          version_ = validate file.content
        else if file.name == AR-ENTRY-METADATA:
          metadata := json.decode file.content
          sdk-version = metadata[META-SDK-VERSION]
          kind-string := metadata[META-KIND]
          if kind-string == KIND-STRING-ESP32:
            kind = KIND-ESP32
          else if kind-string == KIND-STRING-HOST:
            kind = KIND-HOST
          else:
            throw "unsupported kind: $kind-string"
          word-size = metadata[META-WORD-SIZE]
        else:
          entries[file.name] = file.content
    if version_ == -1: throw "cannot open envelope - missing info entry"
    if sdk-version == "": throw "cannot open envelope - missing or corrupt metadata entry"

  constructor.create .entries --.sdk-version --.kind --.word-size:
    version_ = ENVELOPE-FORMAT-VERSION

  store path/string --ui/cli.Ui -> none:
    write-file path --ui=ui: | writer/io.Writer |
      ar := ar.ArWriter writer

      // Add the envelope info entry.
      info := ByteArray INFO-ENTRY-SIZE
      LITTLE-ENDIAN.put-uint32 info INFO-ENTRY-MARKER-OFFSET MARKER
      LITTLE-ENDIAN.put-uint32 info INFO-ENTRY-VERSION-OFFSET version_
      ar.add AR-ENTRY-INFO info

      kind-string := ""
      if kind == KIND-ESP32:
        kind-string = KIND-STRING-ESP32
      else if kind == KIND-HOST:
        kind-string = KIND-STRING-HOST
      else:
        throw "unsupported kind: $(kind)"

      metadata := json.encode {
        META-SDK-VERSION: sdk-version,
        META-KIND: kind-string,
        META-WORD-SIZE: word-size,
      }
      ar.add AR-ENTRY-METADATA metadata

      // Add all other entries.
      entries.do: | name/string content/ByteArray |
        ar.add name content

  static validate info/ByteArray -> int:
    if info.size < INFO-ENTRY-SIZE:
      throw "cannot open envelope - malformed"
    marker := LITTLE-ENDIAN.uint32 info 0
    version := LITTLE-ENDIAN.uint32 info 4
    if marker != MARKER:
      throw "cannot open envelope - malformed"
    if version != ENVELOPE-FORMAT-VERSION:
      throw "cannot open envelope - expected version $ENVELOPE-FORMAT-VERSION, was $version"
    return version

class RelocationInformation:
  relocation-bytes/ByteArray
  word-size/int  // In bytes.

  constructor.from relocatable/ByteArray --.word-size:
    chunk-size := get-relocatable-chunk-byte-size --word-size=word-size
    chunk-count := ceil_ relocatable.size chunk-size
    relocation-bytes = ByteArray chunk-count * word-size
    for i := 0; i < chunk-count; i++:
      relocation-bytes.replace (i * word-size) relocatable[i * chunk-size..i * chunk-size + word-size]

  /**
  Applies the relocation information to the given relocated $image.

  The provided $image may be bigger than the original relocatable image from which
    the relocation information was extracted. In that case the extra bytes are
    assumed not to contain pointers.
  */
  apply-to image/ByteArray -> ByteArray:
    relocatable-chunk-size := get-relocatable-chunk-byte-size --word-size=word-size
    relocated-chunk-size := get-relocated-chunk-byte-size --word-size=word-size
    result := ByteArray (ceil_ image.size relocated-chunk-size) * relocatable-chunk-size

    image-offset := 0
    result-offset := 0
    relocation-offset := 0
    // We are attaching assets to the image, so for some parts of the image we
    // don't always have relocation information. Just use a zero-filled word.
    no-relocation-bytes := ByteArray word-size
    List.chunk-up 0 image.size relocated-chunk-size: | from/int to/int chunk-size/int |
      chunk := image[from..to]
      image-offset += chunk-size

      relocation-info := relocation-offset < relocation-bytes.size
          ? relocation-bytes[relocation-offset..relocation-offset + word-size]
          : no-relocation-bytes
      relocation-offset += word-size

      result.replace result-offset relocation-info
      result-offset += relocation-info.size
      result.replace result-offset chunk
      result-offset += chunk-size

    return result

  static relocated-size relocatable-size/int --word-size/int -> int:
    relocatable-chunk-size := get-relocatable-chunk-byte-size --word-size=word-size
    relocated-chunk-size := get-relocated-chunk-byte-size --word-size=word-size
    chunk-count := ceil_ relocatable-size relocatable-chunk-size
    // One word of every chunk is used for relocation information.
    return chunk-count * relocated-chunk-size

  static get-relocatable-chunk-byte-size --word-size/int -> int:
    word-bit-size := word-size * 8
    // One word for the relocation-information, followed by one word for each bit of it.
    chunk-word-size := 1 + word-bit-size
    return chunk-word-size * word-size

  static get-relocated-chunk-byte-size --word-size/int -> int:
    word-bit-size := word-size * 8
    return word-size * word-bit-size

ceil_ x/int y/int -> int:
  return (x + y - 1) / y

class ContainerEntry:
  id/Uuid
  name/string
  flags/int
  relocatable/ByteArray
  assets/ByteArray?
  word-size/int

  constructor .id .name .relocatable --.flags --.assets --.word-size:

  relocated-size -> int:
    return relocatable.size - (RelocationInformation.relocated-size relocatable.size --word-size=word-size)

  /**
  Relocates the container to the given $relocation-base and updates the header.

  Also attaches the container's assets if $attach-assets is true.

  The header is updated with the given $system-uuid and the container's $flags.
  */
  relocate --relocation-base/int --attach-assets/bool --system-uuid/Uuid -> ByteArray:
    out := io.Buffer
    output := BinaryRelocatedOutput out relocation-base --word-size=word-size
    output.write relocatable
    image-bits := out.bytes
    image-bits = pad image-bits 4

    image-header ::= ImageHeader image-bits --word-size=word-size
    image-header.system-uuid = system-uuid
    image-header.flags = flags

    if attach-assets and assets:
      image-header.flags |= IMAGE-FLAG-HAS-ASSETS
      assets-size := ByteArray 4
      LITTLE-ENDIAN.put-uint32 assets-size 0 assets.size
      image-bits += assets-size
      image-bits += assets
      image-bits = pad image-bits 4

    return image-bits

  relocation-information -> RelocationInformation:
    return RelocationInformation.from relocatable --word-size=word-size

class ImageHeader:
  static MARKER-OFFSET_        ::= 0
  static ID-OFFSET_            ::= 8
  static METADATA-OFFSET_      ::= 24
  static UUID-OFFSET_          ::= 32

  static MARKER_ ::= 0xdeadface

  header_/ByteArray
  word-size/int

  constructor image/ByteArray --.word-size:
    header_ = validate image --word-size=word-size

  static snapshot-uuid-offset_ word-size/int -> int:
    return 48 + 7 * 2 * word-size  // 7 tables and lists.

  static header-size_ word-size/int -> int:
    return (snapshot-uuid-offset_ word-size) + Uuid.SIZE

  flags -> int:
    return header_[METADATA-OFFSET_]

  flags= value/int -> none:
    header_[METADATA-OFFSET_] = value

  id -> Uuid:
    return read-uuid_ ID-OFFSET_

  snapshot-uuid -> Uuid:
    return read-uuid_ (snapshot-uuid-offset_ word-size)

  system-uuid -> Uuid:
    return read-uuid_ UUID-OFFSET_

  system-uuid= value/Uuid -> none:
    write-uuid_ UUID-OFFSET_ value

  read-uuid_ offset/int -> Uuid:
    return Uuid header_[offset .. offset + Uuid.SIZE]

  write-uuid_ offset/int value/Uuid -> none:
    header_.replace offset value.to-byte-array

  static validate image/ByteArray --word-size/int -> ByteArray:
    if image.size < (header-size_ word-size): throw "image too small"
    marker := LITTLE-ENDIAN.uint32 image MARKER-OFFSET_
    if marker != MARKER_: throw "image has wrong marker ($(%x marker) != $(%x MARKER_))"
    return image[0..(header-size_ word-size)]

/*
The image format is as follows:

  typedef struct {
    uint8_t magic;              /*!< Magic word ESP_IMAGE_HEADER_MAGIC */
    uint8_t segment_count;      /*!< Count of memory segments */
    uint8_t spi_mode;           /*!< flash read mode (esp_image_spi_mode_t as uint8_t) */
    uint8_t spi_speed: 4;       /*!< flash frequency (esp_image_spi_freq_t as uint8_t) */
    uint8_t spi_size: 4;        /*!< flash chip size (esp_image_flash_size_t as uint8_t) */
    uint32_t entry_addr;        /*!< Entry address */
    uint8_t wp_pin;             /*!< WP pin when SPI pins set via efuse (read by ROM bootloader,
                                * the IDF bootloader uses software to configure the WP
                                * pin and sets this field to 0xEE=disabled) */
    uint8_t spi_pin_drv[3];     /*!< Drive settings for the SPI flash pins (read by ROM bootloader) */
    esp_chip_id_t chip_id;      /*!< Chip identification number */
    uint8_t min_chip_rev;       /*!< Minimum chip revision supported by image */
    uint8_t reserved[8];        /*!< Reserved bytes in additional header space, currently unused */
    uint8_t hash_appended;      /*!< If 1, a SHA256 digest "simple hash" (of the entire image) is appended after the checksum.
                                * Included in image length. This digest
                                * is separate to secure boot and only used for detecting corruption.
                                * For secure boot signed images, the signature
                                * is appended after this (and the simple hash is included in the signed data). */
  } __attribute__((packed)) esp_image_header_t;

See https://docs.espressif.com/projects/esp-idf/en/latest/api-reference/system/app_image_format.html
for more details on the format.
*/

interface AddressMap:
  drom-map-start -> int
  drom-map-end -> int

// See <<chiptype>/include/soc/soc.h for these constants.
// drom-map-start is the constant SOC_DROM_LOW.
// drom-map-end is the constant SOC_DROM_HIGH.
class Esp32AddressMap implements AddressMap:
  drom-map-start ::= 0x3f400000
  drom-map-end   ::= 0x3f800000

class Esp32C3AddressMap implements AddressMap:
  drom-map-start ::= 0x3c000000
  drom-map-end   ::= 0x3c800000

class Esp32C6AddressMap implements AddressMap:
  // TODO(florian): the DROM map is dependent on SOC_MMU_PAGE_SIZE which
  // can be configured through sdkconfig.
  drom-map-start ::= 0x42000000
  drom-map-end   ::= 0x43000000

class Esp32S2AddressMap implements AddressMap:
  drom-map-start ::= 0x3f000000
  drom-map-end   ::= 0x3ff80000

class Esp32S3AddressMap implements AddressMap:
  drom-map-start ::= 0x3c000000
  drom-map-end   ::= 0x3e000000

class Esp32Binary:
  static MAGIC-OFFSET_         ::= 0
  static SEGMENT-COUNT-OFFSET_ ::= 1
  static CHIP-ID-OFFSET_       ::= 12
  static HASH-APPENDED-OFFSET_ ::= 23
  static HEADER-SIZE_          ::= 24

  static ESP-IMAGE-HEADER-MAGIC_ ::= 0xe9
  static ESP-CHECKSUM-MAGIC_     ::= 0xef

  // Chip IDs are defined in Kconfig ('IDF_FIRMWARE_CHIP_ID').
  static ESP-CHIP-ID-ESP32    ::= 0x0000  // Chip ID: ESP32.
  static ESP-CHIP-ID-ESP32-C3 ::= 0x0005  // Chip ID: ESP32-C3.
  static ESP-CHIP-ID-ESP32-C6 ::= 0x000d  // Chip ID: ESP32-C6.
  static ESP-CHIP-ID-ESP32-H2 ::= 0x000a  // Chip ID: ESP32-H2.
  static ESP-CHIP-ID-ESP32-S2 ::= 0x0002  // Chip ID: ESP32-S2.
  static ESP-CHIP-ID-ESP32-S3 ::= 0x0009  // Chip ID: ESP32-S3.

  static CHIP-ADDRESS-MAPS_ ::= {
      ESP-CHIP-ID-ESP32    : Esp32AddressMap,
      ESP-CHIP-ID-ESP32-C3 : Esp32C3AddressMap,
      ESP-CHIP-ID-ESP32-C6 : Esp32C6AddressMap,
      ESP-CHIP-ID-ESP32-S2 : Esp32S2AddressMap,
      ESP-CHIP-ID-ESP32-S3 : Esp32S3AddressMap,
  }

  static CHIP-NAMES_ ::= {
      ESP-CHIP-ID-ESP32    : "esp32",
      ESP-CHIP-ID-ESP32-C3 : "esp32c3",
      ESP-CHIP-ID-ESP32-C6 : "esp32c6",
      ESP-CHIP-ID-ESP32-H2 : "esp32h2",
      ESP-CHIP-ID-ESP32-S2 : "esp32s2",
      ESP-CHIP-ID-ESP32-S3 : "esp32s3",
  }

  header_/ByteArray
  segments_/List
  chip-id_/int
  address-map_/AddressMap

  constructor bits/ByteArray:
    header_ = bits[0..HEADER-SIZE_]
    if bits[MAGIC-OFFSET_] != ESP-IMAGE-HEADER-MAGIC_:
      throw "cannot handle binary file: magic is wrong"
    chip-id_ = bits[CHIP-ID-OFFSET_]
    if not CHIP-ADDRESS-MAPS_.contains chip-id_:
      throw "unsupported chip id: $chip-id_"
    address-map_ = CHIP-ADDRESS-MAPS_[chip-id_]
    offset := HEADER-SIZE_
    segments_ = List header_[SEGMENT-COUNT-OFFSET_]:
      segment := read-segment_ bits offset
      offset = segment.end
      segment

  chip-name -> string:
    return CHIP-NAMES_[chip-id_]

  bits -> ByteArray:
    // The total size of the resulting byte array must be
    // padded so it has 16-byte alignment. We place the
    // the XOR-based checksum as the last byte before that
    // boundary.
    end := segments_.last.end
    xor-checksum-offset/int := (round-up end + 1 16) - 1
    size := xor-checksum-offset + 1
    sha-checksum-offset/int? := null
    if hash-appended:
      sha-checksum-offset = size
      size += 32
    // Construct the resulting byte array and write the segments
    // into it. While we do that, we also compute the XOR-based
    // checksum and store it at the end.
    result := ByteArray size
    result.replace 0 header_
    xor-checksum := ESP-CHECKSUM-MAGIC_
    segments_.do: | segment/Esp32BinarySegment |
      xor-checksum ^= segment.xor-checksum
      write-segment_ result segment
    result[xor-checksum-offset] = xor-checksum
    // Update the SHA256 checksum if necessary.
    if sha-checksum-offset:
      sha-checksum := crypto.sha256 result 0 sha-checksum-offset
      result.replace sha-checksum-offset sha-checksum
    return result

  parts bits/ByteArray -> List:
    drom := find-last-drom-segment_
    if not drom: throw "cannot find drom segment"
    result := []
    extension-size := compute-drom-extension-size_ drom
    // The segments before the last DROM segment is part of the
    // original binary, so we combine them into one part.
    unextended-size := extension-size[0] + Esp32BinarySegment.HEADER-SIZE_
    offset := collect-part_ result "binary" --from=0 --to=(drom.offset + unextended-size)
    // The container images are stored in the beginning of the DROM segment extension.
    extension-used := extension-size[1]
    offset = collect-part_ result "images" --from=offset --size=extension-used
    // The config part is the free space in the DROM segment extension.
    extension-free := extension-size[2]
    offset = collect-part_ result "config" --from=offset --size=extension-free
    // The segments that follow the last DROM segment are part of the
    // original binary, so we combine them into one part.
    size-no-checksum := bits.size - 1
    if hash-appended: size-no-checksum -= 32
    offset = collect-part_ result "binary" --from=drom.end --to=size-no-checksum
    // Always add the checksum as a separate part.
    collect-part_ result "checksum" --from=offset --to=bits.size
    return result

  static collect-part_ parts/List type/string --from/int --size/int -> int:
    return collect-part_ parts type --from=from --to=(from + size)

  static collect-part_ parts/List type/string --from/int --to/int -> int:
    parts.add { "type": type, "from": from, "to": to }
    return to

  hash-appended -> bool:
    return header_[HASH-APPENDED-OFFSET_] == 1

  extend-drom-address -> int:
    drom := find-last-drom-segment_
    if not drom: throw "cannot append to non-existing DROM segment"
    return drom.address + drom.size

  patch-extend-drom system-uuid/Uuid table-address/int bits/ByteArray -> none:
    if (bits.size & 0xffff) != 0: throw "cannot extend with partial flash pages (64KB)"
    // We look for the last DROM segment, because it will grow into
    // unused virtual memory, so we can extend that without relocating
    // other segments (which we don't know how to).
    drom := find-last-drom-segment_
    if not drom: throw "cannot append to non-existing DROM segment"
    transform-drom-segment_ drom: | segment/ByteArray |
      patch-details-esp32 segment system-uuid table-address
      segment + bits

  remove-drom-extension bits/ByteArray -> none:
    drom := find-last-drom-segment_
    if not drom: return
    extension-size := compute-drom-extension-size_ drom
    transform-drom-segment_ drom: it[..extension-size[0]]

  static compute-drom-extension-size_ drom/Esp32BinarySegment -> List:
    details-offset := find-details-offset-esp32 drom.bits
    unextended-end-address := LITTLE-ENDIAN.uint32 drom.bits details-offset
    if unextended-end-address == 0: return [drom.size, 0, 0]
    unextended-size := unextended-end-address - drom.address
    extension-size := drom.size - unextended-size
    if extension-size < 5 * 4: throw "malformed drom extension (size)"
    marker := LITTLE-ENDIAN.uint32 drom.bits unextended-size
    if marker != 0x98dfc301: throw "malformed drom extension (marker)"
    checksum := 0
    5.repeat: checksum ^= LITTLE-ENDIAN.uint32 drom.bits unextended-size + 4 * it
    if checksum != 0xb3147ee9: throw "malformed drom extension (checksum)"
    used := LITTLE-ENDIAN.uint32 drom.bits unextended-size + 4
    free := LITTLE-ENDIAN.uint32 drom.bits unextended-size + 8
    return [unextended-size, used, free]

  transform-drom-segment_ drom/Esp32BinarySegment [block] -> none:
    // Run through all the segments and transform the DROM one.
    // All segments following that must be displaced in flash if
    // the DROM segment changed size.
    displacement := 0
    segments_.size.repeat:
      segment/Esp32BinarySegment := segments_[it]
      if segment == drom:
        bits := segment.bits
        size-before := bits.size
        transformed := block.call bits
        size-after := transformed.size
        segments_[it] = Esp32BinarySegment transformed
            --offset=segment.offset
            --address=segment.address
        displacement = size-after - size-before
      else if displacement != 0:
        segments_[it] = Esp32BinarySegment segment.bits
            --offset=segment.offset + displacement
            --address=segment.address

  find-last-drom-segment_ -> Esp32BinarySegment?:
    last := null
    address-map/AddressMap? := CHIP-ADDRESS-MAPS_.get chip-id_
    segments_.do: | segment/Esp32BinarySegment |
      address := segment.address
      if not address-map_.drom-map-start <= address < address-map_.drom-map-end: continue.do
      if not last or address > last.address: last = segment
    return last

  static read-segment_ bits/ByteArray offset/int -> Esp32BinarySegment:
    address := LITTLE-ENDIAN.uint32 bits
        offset + Esp32BinarySegment.LOAD-ADDRESS-OFFSET_
    size := LITTLE-ENDIAN.uint32 bits
        offset + Esp32BinarySegment.DATA-LENGTH-OFFSET_
    start := offset + Esp32BinarySegment.HEADER-SIZE_
    return Esp32BinarySegment bits[start..start + size]
        --offset=offset
        --address=address

  static write-segment_ bits/ByteArray segment/Esp32BinarySegment -> none:
    offset := segment.offset
    LITTLE-ENDIAN.put-uint32 bits
        offset + Esp32BinarySegment.LOAD-ADDRESS-OFFSET_
        segment.address
    LITTLE-ENDIAN.put-uint32 bits
        offset + Esp32BinarySegment.DATA-LENGTH-OFFSET_
        segment.size
    bits.replace (offset + Esp32BinarySegment.HEADER-SIZE_) segment.bits

class Esp32BinarySegment:
  static LOAD-ADDRESS-OFFSET_ ::= 0
  static DATA-LENGTH-OFFSET_  ::= 4
  static HEADER-SIZE_         ::= 8

  bits/ByteArray
  offset/int
  address/int

  constructor .bits --.offset --.address:

  size -> int:
    return bits.size

  end -> int:
    return offset + HEADER-SIZE_ + size

  xor-checksum -> int:
    // XOR all the bytes together using blit.
    result := #[0]
    bitmap.blit bits result bits.size
        --destination-pixel-stride=0
        --operation=bitmap.XOR
    return result[0]

  stringify -> string:
    return "len 0x$(%05x size) load 0x$(%08x address) file_offs 0x$(%08x offset)"

IMAGE-DATA-MAGIC-1 ::= 0x7017da7a
IMAGE-DETAILS-SIZE ::= 4 + Uuid.SIZE
IMAGE-DATA-MAGIC-2 ::= 0x00c09f19

// The DROM segment contains a section where we patch in the image details.
patch-details-esp32 bits/ByteArray unique-id/Uuid table-address/int -> none:
  // Patch the binary at the offset we compute by searching for
  // the magic markers. We store the programs table address and
  // the uuid.
  bundled-programs-table-address := ByteArray 4
  LITTLE-ENDIAN.put-uint32 bundled-programs-table-address 0 table-address
  offset := find-details-offset-esp32 bits
  bits.replace (offset + 0) bundled-programs-table-address
  bits.replace (offset + 4) unique-id.to-byte-array

// Searches for two magic numbers that surround the image details area.
// This is the area in the image that is patched with the details.
// The exact location of this area can depend on a future SDK version
// so we don't know it exactly.
find-details-offset-esp32 bits/ByteArray -> int:
  limit := bits.size - IMAGE-DETAILS-SIZE
  for offset := 0; offset < limit; offset += WORD-SIZE-ESP32:
    word-1 := LITTLE-ENDIAN.uint32 bits offset
    if word-1 != IMAGE-DATA-MAGIC-1: continue
    candidate := offset + WORD-SIZE-ESP32
    word-2 := LITTLE-ENDIAN.uint32 bits candidate + IMAGE-DETAILS-SIZE
    if word-2 == IMAGE-DATA-MAGIC-2: return candidate
  // No magic numbers were found so the image is from a legacy SDK that has the
  // image details at a fixed offset.
  throw "cannot find magic marker in binary file"
