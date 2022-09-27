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
import bytes
import crypto.sha256 as crypto
import writer
import reader
import uuid

import encoding.json
import encoding.ubjson
import system.assets

import ar
import cli
import host.file

import .image
import .snapshot
import .snapshot_to_image

ENVELOPE_FORMAT_VERSION ::= 4

WORD_SIZE ::= 4
AR_ENTRY_FIRMWARE_BIN    ::= "\$firmware.bin"
AR_ENTRY_FIRMWARE_ELF    ::= "\$firmware.elf"
AR_ENTRY_BOOTLOADER_BIN  ::= "\$bootloader.bin"
AR_ENTRY_PARTITIONS_BIN  ::= "\$partitions.bin"
AR_ENTRY_PARTITIONS_CSV  ::= "\$partitions.csv"
AR_ENTRY_SYSTEM_SNAPSHOT ::= "\$system.snap"
AR_ENTRY_PROPERTIES      ::= "\$properties"

AR_ENTRY_FILE_MAP ::= {
  "firmware.bin"    : AR_ENTRY_FIRMWARE_BIN,
  "firmware.elf"    : AR_ENTRY_FIRMWARE_ELF,
  "bootloader.bin"  : AR_ENTRY_BOOTLOADER_BIN,
  "partitions.bin"  : AR_ENTRY_PARTITIONS_BIN,
  "partitions.csv"  : AR_ENTRY_PARTITIONS_CSV,
  "system.snapshot" : AR_ENTRY_SYSTEM_SNAPSHOT,
}

OPTION_ENVELOPE     ::= "envelope"
OPTION_OUTPUT       ::= "output"
OPTION_OUTPUT_SHORT ::= "o"

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
  root_cmd.add container_cmd
  root_cmd.add property_cmd
  root_cmd.run arguments

create_cmd -> cli.Command:
  options := AR_ENTRY_FILE_MAP.map: | key/string value/string |
    cli.OptionString key
        --short_help="Set the $key part."
        --type="file"
        --required=(key == "firmware.bin")
  return cli.Command "create"
      --options=options.values
      --run=:: create_envelope it

create_envelope parsed/cli.Parsed -> none:
  output_path := parsed[OPTION_ENVELOPE]
  input_path := parsed["firmware.bin"]

  // TODO(kasper): Do some sanity checks on the
  // structure of this. Can we check that we don't
  // already have stuff appended to the DROM section?
  firmware_bin_data := read_file input_path
  Esp32Binary firmware_bin_data

  entries := { AR_ENTRY_FIRMWARE_BIN: firmware_bin_data }
  AR_ENTRY_FILE_MAP.do: | key/string value/string |
    if key == "firmware.bin": continue.do
    entries[value] = read_file parsed[key]

  envelope := Envelope.create entries
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
                --short_help="Add assets to the image."
                --type="file"
          ]
          --rest=[
            option_name,
            cli.OptionString "image"
                --type="file"
                --required
          ]
          --run=:: container_install it

  cmd.add
      cli.Command "uninstall"
          --options=[ option_output ]
          --rest=[ option_name ]
          --run=:: container_uninstall it

  cmd.add
      cli.Command "list"
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

container_install parsed/cli.Parsed -> none:
  name := parsed["name"]
  image_path := parsed["image"]
  assets_path := parsed["assets"]
  if name.starts_with "\$":
    print "cannot install container with a name that starts with \$ or +"
    exit 1
  if name.size > 14:
    print "cannot install container with a name longer than 14 characters"
    exit 1
  image_data := read_file image_path
  assets_data := read_assets assets_path
  if not is_snapshot_bundle image_data:
    // We're not dealing with a snapshot, so make sure
    // the provided image is a valid relocatable image.
    header := null
    catch: header = decode_image image_data
    // TODO(kasper): Can we validate that the output
    // fits with the version of the SDK used to compile
    // the embedded binary?
    if not header:
      print "Input is not a valid snapshot or image ('$image_path')."
      exit 1
  else:
    // TODO(kasper): Can we check that the snapshot
    // fits with the version of the SDK used to compile
    // the embedded binary?
    SnapshotBundle name image_data
  update_envelope parsed: | envelope/Envelope |
    envelope.entries[name] = image_data
    if assets_data: envelope.entries["+$name"] = assets_data
    else: envelope.entries.remove "+$name"

container_uninstall parsed/cli.Parsed -> none:
  name := parsed["name"]
  update_envelope parsed: | envelope/Envelope |
    envelope.entries.remove name
    envelope.entries.remove "+$name"

container_list parsed/cli.Parsed -> none:
  input_path := parsed[OPTION_ENVELOPE]
  entries := (Envelope.load input_path).entries
  output := {:}
  entries.do: | name/string content/ByteArray |
    if name.starts_with "\$" or name.starts_with "+": continue.do
    entry := {:}
    if is_snapshot_bundle content:
      bundle := SnapshotBundle name content
      entry["kind"] = "snapshot"
      entry["id"] = bundle.uuid.stringify
    else:
      header := decode_image content
      entry["kind"] = "image"
      entry["id"] = header.id.stringify
    assets := entries.get "+$name"
    if assets: entry["assets"] = { "size": assets.size }
    output[name] = entry
  print (json.stringify output)

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

  entries := (Envelope.load input_path).entries
  entry := entries.get AR_ENTRY_PROPERTIES
  if not entry: return

  properties := json.decode entry
  if key:
    if properties.contains key:
      print (json.stringify (properties.get key))
  else:
    print (json.stringify properties)

property_remove parsed/cli.Parsed -> none:
  properties_update parsed: | properties/Map? key/string |
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
  properties_update parsed: | properties/Map? key/string |
    if key == "uuid":
      exception := catch: uuid.parse value
      if exception: throw "cannot parse uuid: $value ($exception)"
    properties = properties or {:}
    properties[key] = value
    properties

properties_update parsed/cli.Parsed [block] -> none:
  key := parsed["key"]
  update_envelope parsed: | envelope/Envelope |
    properties_data/ByteArray? := envelope.entries.get AR_ENTRY_PROPERTIES
    properties/Map? := properties_data ? (json.decode properties_data) : null
    properties = block.call properties key
    if properties: envelope.entries[AR_ENTRY_PROPERTIES] = json.encode properties

extract_cmd -> cli.Command:
  flags := AR_ENTRY_FILE_MAP.map: | key/string value/string |
    cli.Flag key
        --short_help="Extract the $key part."
  return cli.Command "extract"
      --options=[
        cli.OptionString OPTION_OUTPUT
            --short_name=OPTION_OUTPUT_SHORT
            --short_help="Set the output file."
            --type="file"
            --required,
      ] + flags.values
      --run=:: extract it

extract parsed/cli.Parsed -> none:
  parts := []
  AR_ENTRY_FILE_MAP.do: | key/string |
    if parsed[key]: parts.add key
  if parts.size == 0:
    throw "cannot extract: no part specified"
  else if parts.size > 1:
    throw "cannot extract: multiple parts specified ($(parts.join ", "))"
  part := parts.first

  input_path := parsed[OPTION_ENVELOPE]
  output_path := parsed[OPTION_OUTPUT]
  envelope := Envelope.load input_path

  content/ByteArray? := null
  if part == "firmware.bin":
    content = extract_binary envelope
  else:
    content = envelope.entries.get AR_ENTRY_FILE_MAP[part]
  if not content:
    throw "cannot extract: no such part ($part)"
  write_file output_path: it.write content

extract_binary envelope/Envelope -> ByteArray:
  firmware_bin/ByteArray? := null
  properties/Map := {:}
  containers ::= []

  entries := envelope.entries
  entries.do: | name/string content/ByteArray |
    if name == AR_ENTRY_FIRMWARE_BIN:
      firmware_bin = content
    else if name == AR_ENTRY_PROPERTIES:
      properties = json.decode content
    else if not (name.starts_with "\$" or name.starts_with "+"):
      assets := entries.get "+$name"
      containers.add (ContainerEntry name content --assets=assets)

  if not firmware_bin:
    throw "cannot find $AR_ENTRY_FIRMWARE_BIN entry in envelope '$envelope.path'"

  system_uuid/uuid.Uuid? := null
  if properties.contains "uuid":
    catch: system_uuid = uuid.parse properties["uuid"]
    properties.remove "uuid"
  if not system_uuid:
    system_uuid = uuid.uuid5 "$random" "$Time.now".to_byte_array

  return extract_binary_content
      --binary_input=firmware_bin
      --containers=containers
      --system_uuid=system_uuid
      --properties=properties

update_envelope parsed/cli.Parsed [block] -> none:
  input_path := parsed[OPTION_ENVELOPE]
  output_path := parsed[OPTION_OUTPUT]
  if not output_path: output_path = input_path

  existing := Envelope.load input_path
  block.call existing

  envelope := Envelope.create existing.entries
  envelope.store output_path

extract_binary_content -> ByteArray
    --binary_input/ByteArray
    --containers/List
    --system_uuid/uuid.Uuid
    --properties/Map:
  binary := Esp32Binary
      inject_config properties system_uuid binary_input
  image_count := containers.size
  image_table := ByteArray 4 + 8 * image_count
  LITTLE_ENDIAN.put_uint32 image_table 0 image_count

  relocation_base := binary.extend_drom_address + image_table.size
  images := []
  index := 0
  containers.do: | container/ContainerEntry |
    relocatable/ByteArray := ?
    if is_snapshot_bundle container.content:
      snapshot_bundle := SnapshotBundle container.name container.content
      program_id ::= snapshot_bundle.uuid
      program := snapshot_bundle.decode
      image := build_image program WORD_SIZE --system_uuid=system_uuid --program_id=program_id
      relocatable = image.build_relocatable
    else:
      relocatable = container.content

    out := bytes.Buffer
    output := BinaryRelocatedOutput out relocation_base
    output.write WORD_SIZE relocatable
    image_bits := out.bytes
    image_size := image_bits.size

    LITTLE_ENDIAN.put_uint32 image_table 4 + index * 8
        relocation_base
    LITTLE_ENDIAN.put_uint32 image_table 8 + index * 8
        image_size
    image_bits = pad image_bits 4

    if container.assets:
      header ::= ImageHeader image_bits
      header.flags |= (1 << 7)
      assets_size := ByteArray 4
      LITTLE_ENDIAN.put_uint32 assets_size 0 container.assets.size
      image_bits += assets_size
      image_bits += container.assets
      image_bits = pad image_bits 4

    images.add image_bits
    relocation_base += image_bits.size
    index++

  extension := image_table
  images.do: extension += it
  binary.extend_drom extension
  return binary.bits

class Envelope:
  static MARKER ::= 0x0abeca70

  static INFO_ENTRY_NAME           ::= "\$envelope"
  static INFO_ENTRY_MARKER_OFFSET  ::= 0
  static INFO_ENTRY_VERSION_OFFSET ::= 4
  static INFO_ENTRY_SIZE           ::= 8

  path/string? ::= null
  version_/int
  entries/Map ::= {:}

  constructor.load .path/string:
    version/int? := null
    read_file path: | reader/reader.Reader |
      ar := ar.ArReader reader
      while file := ar.next:
        if file.name == INFO_ENTRY_NAME:
          version = validate file.content
        else:
          entries[file.name] = file.content
    version_ = version

  constructor.create .entries:
    version_ = ENVELOPE_FORMAT_VERSION

  store path/string -> none:
    write_file path: | writer/writer.Writer |
      ar := ar.ArWriter writer
      // Add the enveloper info entry.
      info := ByteArray INFO_ENTRY_SIZE
      LITTLE_ENDIAN.put_uint32 info INFO_ENTRY_MARKER_OFFSET MARKER
      LITTLE_ENDIAN.put_uint32 info INFO_ENTRY_VERSION_OFFSET version_
      ar.add INFO_ENTRY_NAME info
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
  name/string
  content/ByteArray
  assets/ByteArray?
  constructor .name .content --.assets:

class ImageHeader:
  static MARKER_OFFSET_   ::= 0
  static ID_OFFSET_       ::= 8
  static METADATA_OFFSET_ ::= 24
  static HEADER_SIZE_     ::= 40

  static MARKER_ ::= 0xdeadface

  header_/ByteArray
  constructor image/ByteArray:
    header_ = validate image

  flags -> int:
    return header_[METADATA_OFFSET_]

  flags= value/int -> none:
    header_[METADATA_OFFSET_] = value

  id -> uuid.Uuid:
    return uuid.Uuid header_[ID_OFFSET_..ID_OFFSET_ + uuid.SIZE]

  static validate image/ByteArray -> ByteArray:
    if image.size < HEADER_SIZE_: throw "image too small"
    marker := LITTLE_ENDIAN.uint32 image MARKER_OFFSET_
    if marker != MARKER_: throw "image has wrong marker ($(%x marker) != $(%x MARKER_))"
    return image[0..HEADER_SIZE_]

/**
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
  IROM_MAP_START -> int
  IROM_MAP_END -> int
  DROM_MAP_START -> int
  DROM_MAP_END -> int

// See <<chiptype>/include/soc/soc.h for these constants
class Esp32AddressMap implements AddressMap:
  IROM_MAP_START := 0x400d0000
  IROM_MAP_END   := 0x40400000
  DROM_MAP_START := 0x3f400000
  DROM_MAP_END   := 0x3f800000

class Esp32C3AddressMap implements AddressMap:
  IROM_MAP_START := 0x42000000
  IROM_MAP_END   := 0x42800000
  DROM_MAP_START := 0x3c000000
  DROM_MAP_END   := 0x3c800000

class Esp32S3AddressMap implements AddressMap:
  IROM_MAP_START := 0x42000000
  IROM_MAP_END   := 0x44000000
  DROM_MAP_START := 0x3c000000
  DROM_MAP_END   := 0x3d000000


class Esp32Binary:
  static MAGIC_OFFSET_         ::= 0
  static SEGMENT_COUNT_OFFSET_ ::= 1
  static CHIP_ID_OFFSET_       ::= 12
  static HASH_APPENDED_OFFSET_ ::= 23
  static HEADER_SIZE_          ::= 24

  static ESP_IMAGE_HEADER_MAGIC_ ::= 0xe9
  static ESP_CHECKSUM_MAGIC_     ::= 0xef

  static ESP_CHIP_ID_ESP32   ::= 0x0000  /*!< chip ID: ESP32 */
  static ESP_CHIP_ID_ESP32S2 ::= 0x0002  /*!< chip ID: ESP32-S2 */
  static ESP_CHIP_ID_ESP32C3 ::= 0x0005 /*!< chip ID: ESP32-C3 */
  static ESP_CHIP_ID_ESP32S3 ::= 0x0009 /*!< chip ID: ESP32-S3 */
  static ESP_CHIP_ID_ESP32H2 ::= 0x000A /*!< chip ID: ESP32-H2 */  // ESP32H2-TODO: IDF-3475

  static CHIP_ADDRESS_MAPS_ := {
      ESP_CHIP_ID_ESP32 : Esp32AddressMap,
      ESP_CHIP_ID_ESP32C3 : Esp32C3AddressMap,
      ESP_CHIP_ID_ESP32S3 : Esp32S3AddressMap
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

  hash_appended -> bool:
    return header_[HASH_APPENDED_OFFSET_] == 1

  extend_drom_address -> int:
    drom := find_last_drom_segment_
    if not drom: throw "Cannot append to non-existing DROM segment"
    return drom.address + drom.size

  extend_drom bits/ByteArray -> none:
    // This is a pretty serious padding up. We do it to guarantee
    // that segments that follow this one do not change their
    // alignment within the individual flash pages, which seems
    // to be a requirement. It might be possible to get away with
    // less padding somehow.
    bits = pad bits 64 * 1024
    // We look for the last DROM segment, because it will grow into
    // unused virtual memory, so we can extend that without relocating
    // other segments (which we don't know how to).
    drom := find_last_drom_segment_
    if not drom: throw "Cannot append to non-existing DROM segment"
    // Run through all the segments and extend the
    // segment we just found. All segments following
    // that one need to be displaced in flash.
    displacement := null
    segments_.size.repeat:
      segment/Esp32BinarySegment := segments_[it]
      if segment == drom:
        segments_[it] = Esp32BinarySegment (segment.bits + bits)
            --offset=segment.offset
            --address=segment.address
        displacement = bits.size
      else if displacement:
        segments_[it] = Esp32BinarySegment segment.bits
            --offset=segment.offset + displacement
            --address=segment.address

  find_last_drom_segment_ -> Esp32BinarySegment?:
    last := null
    address_map/AddressMap? := CHIP_ADDRESS_MAPS_.get chip_id_

    segments_.do: | segment/Esp32BinarySegment |
      address := segment.address
      if not address_map_.DROM_MAP_START <= address < address_map_.DROM_MAP_END: continue.do
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
    result := 0
    bits.do: result ^= it
    return result

  stringify -> string:
    return "len 0x$(%05x size) load 0x$(%08x address) file_offs 0x$(%08x offset)"

IMAGE_DATA_MAGIC_1 ::= 0x7017da7a
IMAGE_DATA_MAGIC_2 ::= 0xc09f19

// The factory image contains an "empty" section of 1024 bytes where we encoded
// the config, so that the image can run completely independently.
inject_config config/Map unique_id/uuid.Uuid bits/ByteArray -> ByteArray:
  image_data_position := find_image_data_position bits
  image_data_offset := image_data_position[0]
  image_data_size := image_data_position[1]
  image_config_size := image_data_size - uuid.SIZE - 4

  config_data := ubjson.encode config
  if config_data.size > image_data_size:
    throw "cannot inline config of $config_data.size bytes (too big)"

  // Determine the address of the bundled programs table by decoding
  // the segments of the binary.
  binary := Esp32Binary bits
  bundled_programs_table_address := ByteArray 4
  LITTLE_ENDIAN.put_uint32 bundled_programs_table_address 0 binary.extend_drom_address

  bits.replace image_data_offset (ByteArray image_data_size)  // Zero out area.
  bits.replace image_data_offset config_data
  bits.replace (image_data_offset + image_config_size) unique_id.to_byte_array
  bits.replace (image_data_offset + image_data_size - 4) bundled_programs_table_address
  return bits

// Searches for two magic numbers that surround the image data area.
// This is the area in the image that is replaced with the config data.
// The exact location of this area can depend on a future SDK version
// so we don't know it exactly.
find_image_data_position bits/ByteArray -> List:
  for i := 0; i < bits.size; i += WORD_SIZE:
    word_1 := LITTLE_ENDIAN.uint32 bits i
    if word_1 == IMAGE_DATA_MAGIC_1:
      // Search for the end at the (0.5k + word_size) position and at
      // subsequent positions up to a data area of 4k.  We only search at these
      // round numbers in order to reduce the chance of false positives.
      for j := 0x200 + WORD_SIZE; j <= 0x1000 + WORD_SIZE and i + j < bits.size; j += 0x200:
        word_2 := LITTLE_ENDIAN.uint32 bits i + j
        if word_2 == IMAGE_DATA_MAGIC_2:
          return [i + WORD_SIZE, j - WORD_SIZE]
  // No magic numbers were found so the image is from a legacy SDK that has the
  // image data at a fixed offset.
  throw "cannot find magic marker in binary file"
