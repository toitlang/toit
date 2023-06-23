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

import binary show LITTLE_ENDIAN
import bitmap
import bytes
import crypto.sha256 as crypto
import writer
import reader
import uuid

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

import .image
import .partition_table
import .snapshot
import .snapshot_to_image

ENVELOPE_FORMAT_VERSION ::= 6

WORD_SIZE ::= 4
AR_ENTRY_FIRMWARE_BIN   ::= "\$firmware.bin"
AR_ENTRY_FIRMWARE_ELF   ::= "\$firmware.elf"
AR_ENTRY_BOOTLOADER_BIN ::= "\$bootloader.bin"
AR_ENTRY_PARTITIONS_BIN ::= "\$partitions.bin"
AR_ENTRY_PARTITIONS_CSV ::= "\$partitions.csv"
AR_ENTRY_OTADATA_BIN    ::= "\$otadata.bin"
AR_ENTRY_FLASHING_JSON  ::= "\$flashing.json"
AR_ENTRY_PROPERTIES     ::= "\$properties"
AR_ENTRY_SDK_VERSION    ::= "\$sdk-version"

AR_ENTRY_FILE_MAP ::= {
  "firmware.bin"    : AR_ENTRY_FIRMWARE_BIN,
  "firmware.elf"    : AR_ENTRY_FIRMWARE_ELF,
  "bootloader.bin"  : AR_ENTRY_BOOTLOADER_BIN,
  "partitions.bin"  : AR_ENTRY_PARTITIONS_BIN,
  "partitions.csv"  : AR_ENTRY_PARTITIONS_CSV,
  "otadata.bin"     : AR_ENTRY_OTADATA_BIN,
  "flashing.json"   : AR_ENTRY_FLASHING_JSON,
}

SYSTEM_CONTAINER_NAME ::= "system"

OPTION_ENVELOPE     ::= "envelope"
OPTION_OUTPUT       ::= "output"
OPTION_OUTPUT_SHORT ::= "o"

PROPERTY_CONTAINER_FLAGS ::= "\$container-flags"

IMAGE_FLAG_RUN_BOOT     ::= 1 << 0
IMAGE_FLAG_RUN_CRITICAL ::= 1 << 1
IMAGE_FLAG_HAS_ASSETS   ::= 1 << 7

is_snapshot_bundle bits/ByteArray -> bool:
  catch: return SnapshotBundle.is_bundle_content bits
  return false

pad bits/ByteArray alignment/int -> ByteArray:
  size := bits.size
  padded_size := round_up size alignment
  return bits + (ByteArray padded_size - size)

read_file path/string -> ByteArray:
  exception := catch:
    return file.read_content path
  print "Failed to open '$path' for reading ($exception)."
  exit 1
  unreachable

read_file path/string [block]:
  stream/file.Stream? := null
  exception := catch: stream = file.Stream.for_read path
  if not stream:
    print "Failed to open '$path' for reading ($exception)."
    exit 1
  try:
    block.call stream
  finally:
    stream.close

write_file path/string [block] -> none:
  stream/file.Stream? := null
  exception := catch: stream = file.Stream.for_write path
  if not stream:
    print "Failed to open '$path' for writing ($exception)."
    exit 1
  try:
    writer := writer.Writer stream
    block.call writer
  finally:
    stream.close

write_file_or_print --path/string? output/string -> none:
  if path:
    write_file path: | writer/writer.Writer |
      writer.write output
      writer.write "\n"
  else:
    print output

main arguments/List:
  root_cmd := cli.Command "root"
      --options=[
        cli.OptionString OPTION_ENVELOPE
            --short_name="e"
            --short_help="Set the envelope to work on."
            --type="file"
            --required
      ]
  root_cmd.add create_cmd
  root_cmd.add extract_cmd
  root_cmd.add flash_cmd
  root_cmd.add container_cmd
  root_cmd.add property_cmd
  root_cmd.add show_cmd
  root_cmd.add tool_cmd
  root_cmd.run arguments

create_cmd -> cli.Command:
  options := AR_ENTRY_FILE_MAP.map: | key/string value/string |
    cli.OptionString key
        --short_help="Set the $key part."
        --type="file"
        --required=(key == "firmware.bin")
  return cli.Command "create"
      --options=options.values + [
        cli.OptionString "system.snapshot"
            --type="file"
            --required,
      ]
      --run=:: create_envelope it

create_envelope parsed/cli.Parsed -> none:
  output_path := parsed[OPTION_ENVELOPE]
  input_path := parsed["firmware.bin"]

  firmware_bin_data := read_file input_path
  binary := Esp32Binary firmware_bin_data
  binary.remove_drom_extension firmware_bin_data

  system_snapshot_content := read_file parsed["system.snapshot"]
  system_snapshot := SnapshotBundle system_snapshot_content

  entries := {
    AR_ENTRY_FIRMWARE_BIN: binary.bits,
    SYSTEM_CONTAINER_NAME: system_snapshot_content,
    AR_ENTRY_PROPERTIES: json.encode {
      PROPERTY_CONTAINER_FLAGS: {
        SYSTEM_CONTAINER_NAME: IMAGE_FLAG_RUN_BOOT | IMAGE_FLAG_RUN_CRITICAL
      }
    }
  }

  AR_ENTRY_FILE_MAP.do: | key/string value/string |
    if key == "firmware.bin": continue.do
    filename := parsed[key]
    if filename: entries[value] = read_file filename

  envelope := Envelope.create entries
      --sdk_version=system_snapshot.sdk_version
  envelope.store output_path

container_cmd -> cli.Command:
  cmd := cli.Command "container"
  option_output := cli.OptionString OPTION_OUTPUT
      --short_name=OPTION_OUTPUT_SHORT
      --short_help="Set the output envelope."
      --type="file"
  option_name := cli.OptionString "name"
      --type="string"
      --required

  cmd.add
      cli.Command "install"
          --options=[
            option_output,
            cli.OptionString "assets"
                --short_help="Add assets to the container."
                --type="file",
            cli.OptionEnum "trigger" ["none", "boot"]
                --short_help="Trigger the container to run automatically."
                --default="boot",
            cli.Flag "critical"
                --short_help="Reboot system if the container terminates.",
          ]
          --rest=[
            option_name,
            cli.OptionString "image"
                --type="file"
                --required
          ]
          --run=:: container_install it

  cmd.add
      cli.Command "extract"
          --options=[
            cli.OptionString "output"
                --short_help="Set the output file name."
                --short_name="o"
                --required,
            cli.OptionEnum "part" ["image", "assets"]
                --short_help="Pick the part of the container to extract."
                --required
          ]
          --rest=[option_name]
          --run=:: container_extract it

  cmd.add
      cli.Command "uninstall"
          --options=[ option_output ]
          --rest=[ option_name ]
          --run=:: container_uninstall it

  cmd.add
      cli.Command "list"
          --options=[
            cli.OptionString "output"
                --short_help="Set the output file name."
                --short_name="o",
            cli.OptionEnum "output-format" ["human", "json"]
                --short_help="Set the output format."
                --default="human",
          ]
          --run=:: container_list it

  return cmd

read_assets path/string? -> ByteArray?:
  if not path: return null
  data := read_file path
  // Try decoding the assets to verify that they
  // have the right structure.
  exception := catch:
    assets.decode data
    return data
  print "Failed to decode the assets in '$path'."
  exit 1
  unreachable

decode_image data/ByteArray -> ImageHeader:
  out := bytes.Buffer
  output := BinaryRelocatedOutput out 0x12345678
  output.write WORD_SIZE data
  decoded := out.bytes
  return ImageHeader decoded

get_container_name parsed/cli.Parsed -> string:
  name := parsed["name"]
  if name.starts_with "\$" or name.starts_with "+":
    print "Cannot install container with a name that starts with \$ or +."
    exit 1
  if name.size == 0:
    print "Cannot install container with an empty name."
    exit 1
  if name.size > 14:
    print "Cannot install container with a name longer than 14 characters."
    exit 1
  return name

is_system_name name/string -> bool:
  // Normally names should have at least a character, but to avoid
  // out-of-bound errors we allow empty names here.
  return name.size == 0 or name[0] == '$'

is_container_name name/string -> bool:
  if not 0 < name.size <= 14: return false
  first := name[0]
  return first != '$' and first != '+'

container_install parsed/cli.Parsed -> none:
  name := get_container_name parsed
  image_path := parsed["image"]
  assets_path := parsed["assets"]
  image_data := read_file image_path
  assets_data := read_assets assets_path
  is_snapshot := is_snapshot_bundle image_data

  update_envelope parsed: | envelope/Envelope |
    if is_snapshot:
      bundle := SnapshotBundle name image_data
      if bundle.sdk_version != envelope.sdk_version:
        print "Snapshot was built by SDK $bundle.sdk_version, but envelope is for SDK $envelope.sdk_version."
        exit 1
    else:
      header := null
      catch: header = decode_image image_data
      if not header:
        print "Input is not a valid snapshot or image ('$image_path')."
        exit 1
      expected_system_uuid := sdk_version_uuid --sdk_version=envelope.sdk_version
      if header.system_uuid != expected_system_uuid:
        print "Image cannot be verified to have been built by SDK $envelope.sdk_version."
        print "Image is for $header.system_uuid, but envelope is $expected_system_uuid."
        exit 1

    envelope.entries[name] = image_data
    if assets_data: envelope.entries["+$name"] = assets_data
    else: envelope.entries.remove "+$name"

    flag_bits := 0
    if parsed["trigger"] == "boot": flag_bits |= IMAGE_FLAG_RUN_BOOT
    if parsed["critical"]: flag_bits |= IMAGE_FLAG_RUN_CRITICAL
    properties_update envelope: | properties/Map? |
      properties = properties or {:}
      flags := properties.get PROPERTY_CONTAINER_FLAGS --init=: {:}
      flags[name] = flag_bits
      properties

container_extract parsed/cli.Parsed -> none:
  input_path := parsed[OPTION_ENVELOPE]
  name := get_container_name parsed
  entries := (Envelope.load input_path).entries
  part := parsed["part"]
  key := (part == "assets") ? "+$name" : name
  if not entries.contains key:
    print "Container '$name' has no $part."
    exit 1
  entry := entries[key]
  write_file parsed["output"]: it.write entry

container_uninstall parsed/cli.Parsed -> none:
  name := get_container_name parsed
  update_envelope parsed: | envelope/Envelope |
    envelope.entries.remove name
    envelope.entries.remove "+$name"

    properties_update envelope: | properties/Map? |
      flags := properties and properties.get PROPERTY_CONTAINER_FLAGS
      if flags: flags.remove name
      properties

container_list parsed/cli.Parsed -> none:
  output_path := parsed[OPTION_OUTPUT]
  input_path := parsed[OPTION_ENVELOPE]
  output_format := parsed["output-format"]
  entries := (Envelope.load input_path).entries

  entries_json := build_entries_json entries
  output := entries_json["containers"]

  output_string := ""
  if output_format == "human":
    output_string = json_to_human output: | chain/List |
      chain.size != 1
  else:
    output_string = json.stringify output

  write_file_or_print --path=output_path output_string

build_entries_json entries/Map -> Map:
  properties/Map? := entries.get AR_ENTRY_PROPERTIES
      --if_present=: json.decode it
  flags := properties and properties.get PROPERTY_CONTAINER_FLAGS
  containers := {:}
  entries.do: | name/string content/ByteArray |
    if not is_container_name name: continue.do
    assets := entries.get "+$name"
    entry := extract_container name flags content --assets=assets
    map := {
      "kind": (is_snapshot_bundle content) ? "snapshot" : "image",
      "id"  : entry.id.to_string,
      "size": content.size,
    }
    if assets:
      map["assets"] = { "size": assets.size }
    if entry.flags != 0:
      flag_names := []
      if (entry.flags & IMAGE_FLAG_RUN_BOOT) != 0:
        flag_names.add "trigger=boot"
      if (entry.flags & IMAGE_FLAG_RUN_CRITICAL) != 0:
        flag_names.add "critical"
      map["flags"] = flag_names
    containers[name] = map
  other_entries := {:}
  entries.do: | name/string content/ByteArray |
    if not is_system_name name: continue.do
    other_entries[name[1..]] = {
      "size": content.size,
    }
  return {
    "containers": containers,
    "entries": other_entries,
  }

property_cmd -> cli.Command:
  cmd := cli.Command "property"

  option_output := cli.OptionString OPTION_OUTPUT
      --short_name=OPTION_OUTPUT_SHORT
      --short_help="Set the output envelope."
      --type="file"
  option_key := cli.OptionString "key"
      --type="string"
  option_key_required := cli.OptionString option_key.name
      --type=option_key.type
      --required

  cmd.add
      cli.Command "get"
          --rest=[ cli.OptionString "key" --type="string" ]
          --run=:: property_get it

  cmd.add
      cli.Command "remove"
          --options=[ option_output ]
          --rest=[ option_key_required ]
          --run=:: property_remove it

  cmd.add
      cli.Command "set"
          --options=[ option_output ]
          --rest=[ option_key_required, cli.OptionString "value" --multi --required ]
          --run=:: property_set it

  return cmd

property_get parsed/cli.Parsed -> none:
  input_path := parsed[OPTION_ENVELOPE]
  key := parsed["key"]

  envelope := Envelope.load input_path
  if key == "sdk-version":
    print envelope.sdk_version
    return

  entries := envelope.entries
  entry := entries.get AR_ENTRY_PROPERTIES
  if not entry: return

  properties := json.decode entry
  if key:
    if properties.contains key:
      print (json.stringify (properties.get key))
  else:
    filtered := properties.filter: not it.starts_with "\$"
    print (json.stringify filtered)

property_remove parsed/cli.Parsed -> none:
  properties_update_with_key parsed: | properties/Map? key/string |
    if properties: properties.remove key
    properties

property_set parsed/cli.Parsed -> none:
  value := parsed["value"].map:
    // Try to parse this as a JSON value, but treat it
    // as a string if it fails.
    element := it
    catch: element = json.parse element
    element
  if value.size == 1: value = value.first
  properties_update_with_key parsed: | properties/Map? key/string |
    if key == "uuid":
      exception := catch: uuid.parse value
      if exception: throw "cannot parse uuid: $value ($exception)"
    properties = properties or {:}
    properties[key] = value
    properties

properties_update envelope/Envelope [block] -> none:
  properties/Map? := envelope.entries.get AR_ENTRY_PROPERTIES
      --if_present=: json.decode it
  properties = block.call properties
  if properties: envelope.entries[AR_ENTRY_PROPERTIES] = json.encode properties

properties_update_with_key parsed/cli.Parsed [block] -> none:
  key/string := parsed["key"]
  if key.starts_with "\$": throw "property keys cannot start with \$"
  if key == "sdk-version": throw "cannot update sdk-version property"
  update_envelope parsed: | envelope/Envelope |
    properties_update envelope: | properties/Map? |
      block.call properties key

extract_cmd -> cli.Command:
  return cli.Command "extract"
      --long_help="""
        Extracts the firmware image of the envelope to a file.

        The following formats are supported:
        - binary: the binary app partition. This format can be used with
          the 'esptool' tool.
        - elf: the ELF file of the executable. This is typically used
          for debugging.
        - ubjson: a UBJSON encoding of the sections of the image.
        - qemu: a full binary image suitable for running on QEMU.

        # QEMU
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
        """
      --options=[
        cli.OptionString OPTION_OUTPUT
            --short_name=OPTION_OUTPUT_SHORT
            --short_help="Set the output file."
            --type="file"
            --required,
        cli.OptionString "config"
            --type="file",
        cli.OptionEnum "format" ["binary", "elf", "ubjson", "qemu"]
            --short_help="Set the output format."
            --default="binary",
      ]
      --run=:: extract it

extract parsed/cli.Parsed -> none:
  input_path := parsed[OPTION_ENVELOPE]
  output_path := parsed[OPTION_OUTPUT]
  envelope := Envelope.load input_path

  config_path := parsed["config"]

  if parsed["format"] == "elf":
    if config_path:
      print "WARNING: config is ignored when extracting elf file"
    write_file output_path: it.write (envelope.entries.get AR_ENTRY_FIRMWARE_ELF)
    return

  config_encoded := ByteArray 0
  if config_path:
    config_encoded = read_file config_path
    exception := catch: ubjson.decode config_encoded
    if exception: config_encoded = ubjson.encode (json.decode config_encoded)
  firmware_bin := extract_binary envelope --config_encoded=config_encoded

  if parsed["format"] == "binary":
    write_file output_path: it.write firmware_bin
    return

  if parsed["format"] == "qemu":
    flashing := envelope.entries.get AR_ENTRY_FLASHING_JSON
        --if_present=: json.decode it
        --if_absent=: throw "cannot create qemu image without 'flashing.json'"

    write_qemu_ output_path firmware_bin envelope
    return

  if not parsed["format"] == "ubjson":
    throw "unknown format: $(parsed["format"])"

  binary := Esp32Binary firmware_bin
  parts := binary.parts firmware_bin
  output := {
    "parts"   : parts,
    "binary"  : firmware_bin,
  }
  write_file output_path: it.write (ubjson.encode output)

write_qemu_ output_path/string firmware_bin/ByteArray envelope/Envelope:
  flashing := envelope.entries.get AR_ENTRY_FLASHING_JSON
      --if_present=: json.decode it
      --if_absent=: throw "cannot create qemu image without 'flashing.json'"

  bundled_partitions_bin := (envelope.entries.get AR_ENTRY_PARTITIONS_BIN)
  partition_table := PartitionTable.decode bundled_partitions_bin

  // TODO(kasper): Allow adding more partitions.
  encoded_partitions_bin := partition_table.encode
  app_partition ::= partition_table.find_app
  otadata_partition := partition_table.find_otadata

  out_image := ByteArray 4 * 1024 * 1024  // 4 MB.
  out_image.replace
      int.parse flashing["bootloader"]["offset"][2..] --radix=16
      envelope.entries.get AR_ENTRY_BOOTLOADER_BIN
  out_image.replace
      int.parse flashing["partition-table"]["offset"][2..] --radix=16
      encoded_partitions_bin
  out_image.replace
      otadata_partition.offset
      envelope.entries.get AR_ENTRY_OTADATA_BIN
  out_image.replace
      app_partition.offset
      firmware_bin
  write_file output_path: it.write out_image

find_esptool_ -> List:
  bin_extension := ?
  bin_name := program_name
  if platform == PLATFORM_WINDOWS:
    bin_name = bin_name.replace --all "\\" "/"
    bin_extension = ".exe"
  else:
    bin_extension = ""

  if esptool_path := os.env.get "ESPTOOL_PATH":
    if esptool_path.ends_with ".py":
      return ["python$bin_extension", esptool_path]
    return [esptool_path]

  if jag_toit_repo_path := os.env.get "JAG_TOIT_REPO_PATH":
    return [
      "python$bin_extension",
      "$jag_toit_repo_path/third_party/esp-idf/components/esptool_py/esptool/esptool.py"
    ]

  list := bin_name.split "/"
  dir := list[..list.size - 1].join "/"
  if bin_name.ends_with ".toit":
    if dir == "": dir = "."
    esptool_py := "$dir/../third_party/esp-idf/components/esptool_py/esptool/esptool.py"
    if file.is_file esptool_py:
      return ["python$bin_extension", esptool_py]
  else:
    esptool := ["$dir/esptool$bin_extension"]
    if file.is_file esptool[0]:
      return esptool
  // Try to find esptool in PATH.
  esptool := ["esptool$bin_extension"]
  catch:
    pipe.backticks esptool "version"
    // Succeeded, so just return it.
    return esptool
  // An exception was thrown.
  // Try to find esptool.py in PATH.
  if platform != PLATFORM_WINDOWS:
    exit_value := pipe.system "esptool.py version > /dev/null 2>&1"
    if exit_value == 0:
      location := pipe.backticks "/bin/sh" "-c" "command -v esptool.py"
      return ["python3", location.trim]
  throw "cannot find esptool"

tool_cmd -> cli.Command:
  return cli.Command "tool"
      --short_help="Provides information about used tools."
      --subcommands=[
        esptool_cmd,
      ]

esptool_cmd -> cli.Command:
  return cli.Command "esptool"
      --aliases=["esp-tool", "esp_tool"]
      --short_help="Prints the path and version of the found esptool."
      --examples=[
        cli.Example "Print the path and version of the found esptool."
            --arguments="-e ignored-envelope"
      ]
      --run=:: esptool it

esptool parsed/cli.Parsed -> none:
  esptool := find_esptool_
  print (esptool.join " ")
  pipe.run_program esptool + ["version"]

flash_cmd -> cli.Command:
  return cli.Command "flash"
      --options=[
        cli.OptionString "config"
            --type="file",
        cli.OptionString "port"
            --type="file"
            --short_name="p"
            --required,
        cli.OptionInt "baud"
            --default=921600,
        cli.OptionEnum "chip" ["esp32", "esp32c3", "esp32s2", "esp32s3"]
            --default="esp32",
        OptionPatterns "partition"
            ["file:<name>=<path>", "empty:<name>=<size>"]
            --short_help="Add a custom partition to the flashed image."
            --split_commas
            --multi,
      ]
      --run=:: flash it

flash parsed/cli.Parsed -> none:
  input_path := parsed[OPTION_ENVELOPE]
  config_path := parsed["config"]
  port := parsed["port"]
  baud := parsed["baud"]
  envelope := Envelope.load input_path

  if platform != PLATFORM_WINDOWS:
    stat := file.stat port
    if not stat or stat[file.ST_TYPE] != file.CHARACTER_DEVICE:
      throw "cannot open port '$port'"

  config_encoded := ByteArray 0
  if config_path:
    config_encoded = read_file config_path
    exception := catch: ubjson.decode config_encoded
    if exception: config_encoded = ubjson.encode (json.decode config_encoded)

  firmware_bin := extract_binary envelope --config_encoded=config_encoded
  binary := Esp32Binary firmware_bin

  esptool := find_esptool_

  flashing := envelope.entries.get AR_ENTRY_FLASHING_JSON
      --if_present=: json.decode it
      --if_absent=: throw "cannot flash without 'flashing.json'"

  bundled_partitions_bin := (envelope.entries.get AR_ENTRY_PARTITIONS_BIN)
  partition_table := PartitionTable.decode bundled_partitions_bin

  // Map the file:<name>=<path> and empty:<name>=<size> partitions
  // to entries in the partition table by allocating at the end
  // of the used part of the flash image.
  partitions := {:}
  parsed_partitions := parsed["partition"]
  parsed_partitions.do: | entry/Map |
    description := ?
    is_file := entry.contains "file"
    if is_file: description = entry["file"]
    else: description = entry["empty"]
    assign_index := description.index_of "="
    if assign_index < 0: throw "malformed partition description '$description'"
    name := description[..assign_index]
    if not (0 < name.size <= 15): throw "malformed partition name '$name'"
    if partitions.contains name: throw "duplicate partition named '$name'"
    value := description[assign_index + 1..]
    partition_content/ByteArray := ?
    if is_file:
      partition_content = read_file value
    else:
      size := int.parse value --on_error=:
        throw "malformed partition size '$value'"
      partition_content = ByteArray size
    partition_content = pad partition_content 4096
    partition := Partition
        --name=name
        --type=0x41  // TODO(kasper): Avoid hardcoding this.
        --subtype=0
        --offset=partition_table.find_first_free_offset
        --size=partition_content.size
        --flags=0
    partitions[name] = [partition, partition_content]
    partition_table.add partition

  encoded_partitions_bin := partition_table.encode
  app_partition ::= partition_table.find_app
  otadata_partition := partition_table.find_otadata

  tmp := directory.mkdtemp "/tmp/toit-flash-"
  try:
    write_file "$tmp/bootloader.bin": it.write (envelope.entries.get AR_ENTRY_BOOTLOADER_BIN)
    write_file "$tmp/partitions.bin": it.write encoded_partitions_bin
    write_file "$tmp/otadata.bin": it.write (envelope.entries.get AR_ENTRY_OTADATA_BIN)
    write_file "$tmp/firmware.bin": it.write firmware_bin

    partition_args := [
      flashing["bootloader"]["offset"],      "$tmp/bootloader.bin",
      flashing["partition-table"]["offset"], "$tmp/partitions.bin",
      "0x$(%x otadata_partition.offset)",    "$tmp/otadata.bin",
      "0x$(%x app_partition.offset)",        "$tmp/firmware.bin"
    ]

    partitions.do: | name/string entry/List |
      offset := (entry[0] as Partition).offset
      content := entry[1] as ByteArray
      path := "$tmp/partition-$offset"
      write_file path: it.write content
      partition_args.add "0x$(%x offset)"
      partition_args.add path

    code := pipe.run_program esptool + [
      "--port", port,
      "--baud", "$baud",
      "--chip", parsed["chip"],
      "--before", flashing["extra_esptool_args"]["before"],
      "--after",  flashing["extra_esptool_args"]["after"]
    ] + [ "write_flash" ] + flashing["write_flash_args"] + partition_args
    if code != 0: exit 1
  finally:
    directory.rmdir --recursive tmp

extract_binary envelope/Envelope --config_encoded/ByteArray -> ByteArray:
  containers ::= []
  entries := envelope.entries
  properties := entries.get AR_ENTRY_PROPERTIES
      --if_present=: json.decode it
      --if_absent=: {:}
  flags := properties and properties.get PROPERTY_CONTAINER_FLAGS

  // The system image, if any, must be the first image, so
  // we reserve space for it in the list of containers.
  has_system_image := entries.contains SYSTEM_CONTAINER_NAME
  if has_system_image: containers.add null

  // Compute relocatable images for all the non-system containers.
  non_system_images := {:}
  entries.do: | name/string content/ByteArray |
    if name == SYSTEM_CONTAINER_NAME or not is_container_name name:
      continue.do  // Skip.
    assets := entries.get "+$name"
    entry := extract_container name flags content --assets=assets
    containers.add entry
    non_system_images[name] = entry.id.to_byte_array

  if has_system_image:
    name := SYSTEM_CONTAINER_NAME
    content := entries[name]
    // TODO(kasper): Take any other system assets into account.
    system_assets := {:}
    // Encode any WiFi information.
    properties.get "wifi" --if_present=: system_assets["wifi"] = tison.encode it
    // Encode any non-system image names.
    if not non_system_images.is_empty: system_assets["images"] = tison.encode non_system_images
    // Encode the system assets and add them to the container.
    assets_encoded := assets.encode system_assets
    containers[0] = extract_container name flags content --assets=assets_encoded

  firmware_bin := entries.get AR_ENTRY_FIRMWARE_BIN
  if not firmware_bin:
    throw "cannot find $AR_ENTRY_FIRMWARE_BIN entry in envelope '$envelope.path'"

  system_uuid/uuid.Uuid? := null
  if properties.contains "uuid":
    catch: system_uuid = uuid.parse properties["uuid"]
  system_uuid = system_uuid or sdk_version_uuid --sdk_version=envelope.sdk_version

  return extract_binary_content
      --binary_input=firmware_bin
      --containers=containers
      --system_uuid=system_uuid
      --config_encoded=config_encoded

extract_container name/string flags/Map? content/ByteArray -> ContainerEntry
    --assets/ByteArray?:
  header/ImageHeader := ?
  relocatable/ByteArray := ?
  if is_snapshot_bundle content:
    snapshot_bundle := SnapshotBundle name content
    snapshot_uuid ::= snapshot_bundle.uuid
    program := snapshot_bundle.decode
    image := build_image program WORD_SIZE
        --system_uuid=uuid.NIL
        --snapshot_uuid=snapshot_uuid
        --assets=assets
    header = ImageHeader image.all_memory
    if header.snapshot_uuid != snapshot_uuid: throw "corrupt snapshot uuid encoding"
    relocatable = image.build_relocatable
  else:
    header = decode_image content
    relocatable = content
  flag_bits := flags and flags.get name
  flag_bits = flag_bits or 0
  return ContainerEntry header.id name relocatable --flags=flag_bits --assets=assets

update_envelope parsed/cli.Parsed [block] -> none:
  input_path := parsed[OPTION_ENVELOPE]
  output_path := parsed[OPTION_OUTPUT]
  if not output_path: output_path = input_path

  existing := Envelope.load input_path
  block.call existing

  envelope := Envelope.create existing.entries
      --sdk_version=existing.sdk_version
  envelope.store output_path

extract_binary_content -> ByteArray
    --binary_input/ByteArray
    --containers/List
    --system_uuid/uuid.Uuid
    --config_encoded/ByteArray:
  binary := Esp32Binary binary_input
  image_count := containers.size
  image_table := ByteArray 8 * image_count

  table_address := binary.extend_drom_address
  relocation_base := table_address + 5 * 4 + image_table.size
  images := []
  index := 0
  containers.do: | container/ContainerEntry |
    relocatable := container.relocatable
    out := bytes.Buffer
    output := BinaryRelocatedOutput out relocation_base
    output.write WORD_SIZE relocatable
    image_bits := out.bytes
    image_size := image_bits.size

    LITTLE_ENDIAN.put_uint32 image_table index * 8
        relocation_base
    LITTLE_ENDIAN.put_uint32 image_table index * 8 + 4
        image_size
    image_bits = pad image_bits 4

    image_header ::= ImageHeader image_bits
    image_header.system_uuid = system_uuid
    image_header.flags = container.flags

    if container.assets:
      image_header.flags |= IMAGE_FLAG_HAS_ASSETS
      assets_size := ByteArray 4
      LITTLE_ENDIAN.put_uint32 assets_size 0 container.assets.size
      image_bits += assets_size
      image_bits += container.assets
      image_bits = pad image_bits 4

    images.add image_bits
    relocation_base += image_bits.size
    index++

  // Build the DROM extension by adding a header in front of the
  // table entries. The header will be patched later when we know
  // the total sizes.
  extension_header := ByteArray 5 * 4
  LITTLE_ENDIAN.put_uint32 extension_header (0 * 4) 0x98dfc301
  LITTLE_ENDIAN.put_uint32 extension_header (3 * 4) image_count
  extension := extension_header + image_table
  images.do: extension += it

  // Now add the device-specific configurations at the end.
  used_size := extension.size
  config_size := ByteArray 4
  LITTLE_ENDIAN.put_uint32 config_size 0 config_encoded.size
  extension += config_size
  extension += config_encoded

  // This is a pretty serious padding up. We do it to guarantee
  // that segments that follow this one do not change their
  // alignment within the individual flash pages, which seems
  // to be a requirement. It might be possible to get away with
  // less padding somehow.
  extension = pad extension 64 * 1024
  free_size := extension.size - used_size

  // Update the extension header.
  checksum := 0xb3147ee9
  LITTLE_ENDIAN.put_uint32 extension (1 * 4) used_size
  LITTLE_ENDIAN.put_uint32 extension (2 * 4) free_size
  4.repeat: checksum ^= LITTLE_ENDIAN.uint32 extension (it * 4)
  LITTLE_ENDIAN.put_uint32 extension (4 * 4) checksum

  binary.patch_extend_drom system_uuid table_address extension
  return binary.bits

show_cmd -> cli.Command:
  return cli.Command "show"
      --short_help="Show the contents of the given firmware envelope."
      --options=[
        cli.OptionEnum "output-format" ["human", "json"]
            --default="human",
        cli.Flag "all"
            --short_help="Show all information, including non-container entries."
            --short_name="a",
        cli.Option "output"
            --short_help="Write output to the given file."
            --short_name="o",
      ]
      --run=:: show it

show parsed/cli.Parsed -> none:
  input_path := parsed[OPTION_ENVELOPE]
  output_path := parsed["output"]
  output_format := parsed["output-format"]
  show_all := parsed["all"]

  envelope := Envelope.load input_path
  entries_json := build_entries_json envelope.entries
  result := {
    "envelope-format-version": envelope.version_,
    "sdk-version": envelope.sdk_version,
    "containers": entries_json["containers"],
  }
  if show_all:
    result["entries"] = entries_json["entries"]

  output := ""
  if output_format == "human":
    output = json_to_human result: | chain/List |
      chain.size != 2 or (chain[0] != "containers" and chain[0] != "entries")
  else:
    output = json.stringify result

  write_file_or_print --path=output_path output

capitalize_ str/string -> string:
  if str == "": return ""
  return str[..1].to_ascii_upper + str[1..]

humanize_key_ key/string -> string:
  parts := key.split "-"
  parts.map --in_place: it == "sdk" ? "SDK" : it
  parts[0] = capitalize_ parts[0]
  return parts.join " "

json_to_human o/any --indentation/int=0 --skip_indentation/bool=false --chain/List=[] [should_humanize] -> string:
  result := ""
  if o is Map:
    o.do: | key/string value |
      new_chain := chain + [key]
      human_key := (should_humanize.call new_chain) ? (humanize_key_ key) : key
      if not skip_indentation:
        result += " " * indentation
      else:
        skip_indentation = false
      result += "$human_key: "
      if value is not Map and value is not List:
        result += "$value\n"
      else:
        result += "\n"
        result += json_to_human value --indentation=(indentation + 2) --chain=new_chain should_humanize
  else if o is List:
    o.do: | value |
      if not skip_indentation:
        result += " " * indentation
      else:
        skip_indentation = false
      result += "-"
      if value is Map:
        result += " "
        result += json_to_human value --indentation=(indentation + 2) --skip_indentation --chain=chain should_humanize
      else if value is List:
        result += "\n"
        result += json_to_human value --indentation=(indentation + 2) --chain=chain should_humanize
      else:
        result += " $value\n"
  else:
    if not skip_indentation:
      result += " " * indentation
    else:
      skip_indentation = false
    result += "$o\n"

  return result

class Envelope:
  static MARKER ::= 0x0abeca70

  static INFO_ENTRY_NAME           ::= "\$envelope"
  static INFO_ENTRY_MARKER_OFFSET  ::= 0
  static INFO_ENTRY_VERSION_OFFSET ::= 4
  static INFO_ENTRY_SIZE           ::= 8

  version_/int

  path/string? ::= null
  sdk_version/string
  entries/Map ::= {:}

  constructor.load .path/string:
    version/int? := null
    sdk_version = ""
    read_file path: | reader/reader.Reader |
      ar := ar.ArReader reader
      while file := ar.next:
        if file.name == INFO_ENTRY_NAME:
          version = validate file.content
        else if file.name == AR_ENTRY_SDK_VERSION:
          sdk_version = file.content.to_string_non_throwing
        else:
          entries[file.name] = file.content
    version_ = version

  constructor.create .entries --.sdk_version:
    version_ = ENVELOPE_FORMAT_VERSION

  store path/string -> none:
    write_file path: | writer/writer.Writer |
      ar := ar.ArWriter writer
      // Add the envelope info entry.
      info := ByteArray INFO_ENTRY_SIZE
      LITTLE_ENDIAN.put_uint32 info INFO_ENTRY_MARKER_OFFSET MARKER
      LITTLE_ENDIAN.put_uint32 info INFO_ENTRY_VERSION_OFFSET version_
      ar.add INFO_ENTRY_NAME info
      ar.add AR_ENTRY_SDK_VERSION sdk_version
      // Add all other entries.
      entries.do: | name/string content/ByteArray |
        ar.add name content

  static validate info/ByteArray -> int:
    if info.size < INFO_ENTRY_SIZE:
      throw "cannot open envelope - malformed"
    marker := LITTLE_ENDIAN.uint32 info 0
    version := LITTLE_ENDIAN.uint32 info 4
    if marker != MARKER:
      throw "cannot open envelope - malformed"
    if version != ENVELOPE_FORMAT_VERSION:
      throw "cannot open envelope - expected version $ENVELOPE_FORMAT_VERSION, was $version"
    return version

class ContainerEntry:
  id/uuid.Uuid
  name/string
  flags/int
  relocatable/ByteArray
  assets/ByteArray?
  constructor .id .name .relocatable --.flags --.assets:

class ImageHeader:
  static MARKER_OFFSET_        ::= 0
  static ID_OFFSET_            ::= 8
  static METADATA_OFFSET_      ::= 24
  static UUID_OFFSET_          ::= 32
  static SNAPSHOT_UUID_OFFSET_ ::= 48 + 7 * 2 * 4  // 7 tables and lists.
  static HEADER_SIZE_          ::= SNAPSHOT_UUID_OFFSET_ + uuid.SIZE

  static MARKER_ ::= 0xdeadface

  header_/ByteArray
  constructor image/ByteArray:
    header_ = validate image

  flags -> int:
    return header_[METADATA_OFFSET_]

  flags= value/int -> none:
    header_[METADATA_OFFSET_] = value

  id -> uuid.Uuid:
    return read_uuid_ ID_OFFSET_

  snapshot_uuid -> uuid.Uuid:
    return read_uuid_ SNAPSHOT_UUID_OFFSET_

  system_uuid -> uuid.Uuid:
    return read_uuid_ UUID_OFFSET_

  system_uuid= value/uuid.Uuid -> none:
    write_uuid_ UUID_OFFSET_ value

  read_uuid_ offset/int -> uuid.Uuid:
    return uuid.Uuid header_[offset .. offset + uuid.SIZE]

  write_uuid_ offset/int value/uuid.Uuid -> none:
    header_.replace offset value.to_byte_array

  static validate image/ByteArray -> ByteArray:
    if image.size < HEADER_SIZE_: throw "image too small"
    marker := LITTLE_ENDIAN.uint32 image MARKER_OFFSET_
    if marker != MARKER_: throw "image has wrong marker ($(%x marker) != $(%x MARKER_))"
    return image[0..HEADER_SIZE_]

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
  irom_map_start -> int
  irom_map_end -> int
  drom_map_start -> int
  drom_map_end -> int

// See <<chiptype>/include/soc/soc.h for these constants.
class Esp32AddressMap implements AddressMap:
  irom_map_start ::= 0x400d0000
  irom_map_end   ::= 0x40400000
  drom_map_start ::= 0x3f400000
  drom_map_end   ::= 0x3f800000

class Esp32C3AddressMap implements AddressMap:
  irom_map_start ::= 0x42000000
  irom_map_end   ::= 0x42800000
  drom_map_start ::= 0x3c000000
  drom_map_end   ::= 0x3c800000

class Esp32S2AddressMap implements AddressMap:
  irom_map_start ::= 0x40080000
  irom_map_end   ::= 0x40800000
  drom_map_start ::= 0x3f000000
  drom_map_end   ::= 0x3ff80000

class Esp32S3AddressMap implements AddressMap:
  irom_map_start ::= 0x42000000
  irom_map_end   ::= 0x44000000
  drom_map_start ::= 0x3c000000
  drom_map_end   ::= 0x3d000000


class Esp32Binary:
  static MAGIC_OFFSET_         ::= 0
  static SEGMENT_COUNT_OFFSET_ ::= 1
  static CHIP_ID_OFFSET_       ::= 12
  static HASH_APPENDED_OFFSET_ ::= 23
  static HEADER_SIZE_          ::= 24

  static ESP_IMAGE_HEADER_MAGIC_ ::= 0xe9
  static ESP_CHECKSUM_MAGIC_     ::= 0xef

  static ESP_CHIP_ID_ESP32    ::= 0x0000  // Chip ID: ESP32.
  static ESP_CHIP_ID_ESP32_S2 ::= 0x0002  // Chip ID: ESP32-S2.
  static ESP_CHIP_ID_ESP32_C3 ::= 0x0005  // Chip ID: ESP32-C3.
  static ESP_CHIP_ID_ESP32_S3 ::= 0x0009  // Chip ID: ESP32-S3.
  static ESP_CHIP_ID_ESP32_H2 ::= 0x000a  // Chip ID: ESP32-H2.

  static CHIP_ADDRESS_MAPS_ := {
      ESP_CHIP_ID_ESP32    : Esp32AddressMap,
      ESP_CHIP_ID_ESP32_C3 : Esp32C3AddressMap,
      ESP_CHIP_ID_ESP32_S2 : Esp32S2AddressMap,
      ESP_CHIP_ID_ESP32_S3 : Esp32S3AddressMap,
  }
  header_/ByteArray
  segments_/List
  chip_id_/int
  address_map_/AddressMap

  constructor bits/ByteArray:
    header_ = bits[0..HEADER_SIZE_]
    if bits[MAGIC_OFFSET_] != ESP_IMAGE_HEADER_MAGIC_:
      throw "cannot handle binary file: magic is wrong"
    chip_id_ = bits[CHIP_ID_OFFSET_]
    if not CHIP_ADDRESS_MAPS_.contains chip_id_:
      throw "unsupported chip id: $chip_id_"
    address_map_ = CHIP_ADDRESS_MAPS_[chip_id_]
    offset := HEADER_SIZE_
    segments_ = List header_[SEGMENT_COUNT_OFFSET_]:
      segment := read_segment_ bits offset
      offset = segment.end
      segment

  bits -> ByteArray:
    // The total size of the resulting byte array must be
    // padded so it has 16-byte alignment. We place the
    // the XOR-based checksum as the last byte before that
    // boundary.
    end := segments_.last.end
    xor_checksum_offset/int := (round_up end + 1 16) - 1
    size := xor_checksum_offset + 1
    sha_checksum_offset/int? := null
    if hash_appended:
      sha_checksum_offset = size
      size += 32
    // Construct the resulting byte array and write the segments
    // into it. While we do that, we also compute the XOR-based
    // checksum and store it at the end.
    result := ByteArray size
    result.replace 0 header_
    xor_checksum := ESP_CHECKSUM_MAGIC_
    segments_.do: | segment/Esp32BinarySegment |
      xor_checksum ^= segment.xor_checksum
      write_segment_ result segment
    result[xor_checksum_offset] = xor_checksum
    // Update the SHA256 checksum if necessary.
    if sha_checksum_offset:
      sha_checksum := crypto.sha256 result 0 sha_checksum_offset
      result.replace sha_checksum_offset sha_checksum
    return result

  parts bits/ByteArray -> List:
    drom := find_last_drom_segment_
    if not drom: throw "cannot find drom segment"
    result := []
    extension_size := compute_drom_extension_size_ drom
    // The segments before the last DROM segment is part of the
    // original binary, so we combine them into one part.
    unextended_size := extension_size[0] + Esp32BinarySegment.HEADER_SIZE_
    offset := collect_part_ result "binary" --from=0 --to=(drom.offset + unextended_size)
    // The container images are stored in the beginning of the DROM segment extension.
    extension_used := extension_size[1]
    offset =  collect_part_ result "images" --from=offset --size=extension_used
    // The config part is the free space in the DROM segment extension.
    extension_free := extension_size[2]
    offset = collect_part_ result "config" --from=offset --size=extension_free
    // The segments that follow the last DROM segment are part of the
    // original binary, so we combine them into one part.
    size_no_checksum := bits.size - 1
    if hash_appended: size_no_checksum -= 32
    offset = collect_part_ result "binary" --from=drom.end --to=size_no_checksum
    // Always add the checksum as a separate part.
    collect_part_ result "checksum" --from=offset --to=bits.size
    return result

  static collect_part_ parts/List type/string --from/int --size/int -> int:
    return collect_part_ parts type --from=from --to=(from + size)

  static collect_part_ parts/List type/string --from/int --to/int -> int:
    parts.add { "type": type, "from": from, "to": to }
    return to

  hash_appended -> bool:
    return header_[HASH_APPENDED_OFFSET_] == 1

  extend_drom_address -> int:
    drom := find_last_drom_segment_
    if not drom: throw "cannot append to non-existing DROM segment"
    return drom.address + drom.size

  patch_extend_drom system_uuid/uuid.Uuid table_address/int bits/ByteArray -> none:
    if (bits.size & 0xffff) != 0: throw "cannot extend with partial flash pages (64KB)"
    // We look for the last DROM segment, because it will grow into
    // unused virtual memory, so we can extend that without relocating
    // other segments (which we don't know how to).
    drom := find_last_drom_segment_
    if not drom: throw "cannot append to non-existing DROM segment"
    transform_drom_segment_ drom: | segment/ByteArray |
      patch_details segment system_uuid table_address
      segment + bits

  remove_drom_extension bits/ByteArray -> none:
    drom := find_last_drom_segment_
    if not drom: return
    extension_size := compute_drom_extension_size_ drom
    if not extension_size: return
    transform_drom_segment_ drom: it[..extension_size[0]]

  static compute_drom_extension_size_ drom/Esp32BinarySegment -> List:
    details_offset := find_details_offset drom.bits
    unextended_end_address := LITTLE_ENDIAN.uint32 drom.bits details_offset
    if unextended_end_address == 0: return [drom.size, 0, 0]
    unextended_size := unextended_end_address - drom.address
    extension_size := drom.size - unextended_size
    if extension_size < 5 * 4: throw "malformed drom extension (size)"
    marker := LITTLE_ENDIAN.uint32 drom.bits unextended_size
    if marker != 0x98dfc301: throw "malformed drom extension (marker)"
    checksum := 0
    5.repeat: checksum ^= LITTLE_ENDIAN.uint32 drom.bits unextended_size + 4 * it
    if checksum != 0xb3147ee9: throw "malformed drom extension (checksum)"
    used := LITTLE_ENDIAN.uint32 drom.bits unextended_size + 4
    free := LITTLE_ENDIAN.uint32 drom.bits unextended_size + 8
    return [unextended_size, used, free]

  transform_drom_segment_ drom/Esp32BinarySegment [block] -> none:
    // Run through all the segments and transform the DROM one.
    // All segments following that must be displaced in flash if
    // the DROM segment changed size.
    displacement := 0
    segments_.size.repeat:
      segment/Esp32BinarySegment := segments_[it]
      if segment == drom:
        bits := segment.bits
        size_before := bits.size
        transformed := block.call bits
        size_after := transformed.size
        segments_[it] = Esp32BinarySegment transformed
            --offset=segment.offset
            --address=segment.address
        displacement = size_after - size_before
      else if displacement != 0:
        segments_[it] = Esp32BinarySegment segment.bits
            --offset=segment.offset + displacement
            --address=segment.address

  find_last_drom_segment_ -> Esp32BinarySegment?:
    last := null
    address_map/AddressMap? := CHIP_ADDRESS_MAPS_.get chip_id_
    segments_.do: | segment/Esp32BinarySegment |
      address := segment.address
      if not address_map_.drom_map_start <= address < address_map_.drom_map_end: continue.do
      if not last or address > last.address: last = segment
    return last

  static read_segment_ bits/ByteArray offset/int -> Esp32BinarySegment:
    address := LITTLE_ENDIAN.uint32 bits
        offset + Esp32BinarySegment.LOAD_ADDRESS_OFFSET_
    size := LITTLE_ENDIAN.uint32 bits
        offset + Esp32BinarySegment.DATA_LENGTH_OFFSET_
    start := offset + Esp32BinarySegment.HEADER_SIZE_
    return Esp32BinarySegment bits[start..start + size]
        --offset=offset
        --address=address

  static write_segment_ bits/ByteArray segment/Esp32BinarySegment -> none:
    offset := segment.offset
    LITTLE_ENDIAN.put_uint32 bits
        offset + Esp32BinarySegment.LOAD_ADDRESS_OFFSET_
        segment.address
    LITTLE_ENDIAN.put_uint32 bits
        offset + Esp32BinarySegment.DATA_LENGTH_OFFSET_
        segment.size
    bits.replace (offset + Esp32BinarySegment.HEADER_SIZE_) segment.bits

class Esp32BinarySegment:
  static LOAD_ADDRESS_OFFSET_ ::= 0
  static DATA_LENGTH_OFFSET_  ::= 4
  static HEADER_SIZE_         ::= 8

  bits/ByteArray
  offset/int
  address/int

  constructor .bits --.offset --.address:

  size -> int:
    return bits.size

  end -> int:
    return offset + HEADER_SIZE_ + size

  xor_checksum -> int:
    // XOR all the bytes together using blit.
    result := #[0]
    bitmap.blit bits result bits.size
        --destination_pixel_stride=0
        --operation=bitmap.XOR
    return result[0]

  stringify -> string:
    return "len 0x$(%05x size) load 0x$(%08x address) file_offs 0x$(%08x offset)"

IMAGE_DATA_MAGIC_1 ::= 0x7017da7a
IMAGE_DETAILS_SIZE ::= 4 + uuid.SIZE
IMAGE_DATA_MAGIC_2 ::= 0x00c09f19

// The DROM segment contains a section where we patch in the image details.
patch_details bits/ByteArray unique_id/uuid.Uuid table_address/int -> none:
  // Patch the binary at the offset we compute by searching for
  // the magic markers. We store the programs table address and
  // the uuid.
  bundled_programs_table_address := ByteArray 4
  LITTLE_ENDIAN.put_uint32 bundled_programs_table_address 0 table_address
  offset := find_details_offset bits
  bits.replace (offset + 0) bundled_programs_table_address
  bits.replace (offset + 4) unique_id.to_byte_array

// Searches for two magic numbers that surround the image details area.
// This is the area in the image that is patched with the details.
// The exact location of this area can depend on a future SDK version
// so we don't know it exactly.
find_details_offset bits/ByteArray -> int:
  limit := bits.size - IMAGE_DETAILS_SIZE
  for offset := 0; offset < limit; offset += WORD_SIZE:
    word_1 := LITTLE_ENDIAN.uint32 bits offset
    if word_1 != IMAGE_DATA_MAGIC_1: continue
    candidate := offset + WORD_SIZE
    word_2 := LITTLE_ENDIAN.uint32 bits candidate + IMAGE_DETAILS_SIZE
    if word_2 == IMAGE_DATA_MAGIC_2: return candidate
  // No magic numbers were found so the image is from a legacy SDK that has the
  // image details at a fixed offset.
  throw "cannot find magic marker in binary file"

// TODO(kasper): Move this to the cli package?
class OptionPatterns extends cli.OptionEnum:
  constructor name/string patterns/List
      --default=null
      --short_name/string?=null
      --short_help/string?=null
      --required/bool=false
      --hidden/bool=false
      --multi/bool=false
      --split_commas/bool=false:
    super name patterns
      --default=default
      --short_name=short_name
      --short_help=short_help
      --required=required
      --hidden=hidden
      --multi=multi
      --split_commas=split_commas

  parse str/string --for_help_example/bool=false -> any:
    if not str.contains ":" and not str.contains "=":
      // Make sure it's a valid one.
      key := super str --for_help_example=for_help_example
      return key

    separator_index := str.index_of ":"
    if separator_index < 0: separator_index = str.index_of "="
    key := str[..separator_index]
    key_with_equals := str[..separator_index + 1]
    if not (values.any: it.starts_with key_with_equals):
      throw "Invalid value for option '$name': '$str'. Valid values are: $(values.join ", ")."

    return {
      key: str[separator_index + 1..]
    }
