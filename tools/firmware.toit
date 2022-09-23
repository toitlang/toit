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
import uuid

import encoding.json
import encoding.ubjson

import ar
import cli
import host.file

import .image
import .snapshot
import .snapshot_to_image

ENVELOPE_FORMAT_VERSION ::= 1

WORD_SIZE ::= 4
AR_ENTRY_BINARY ::= "\$binary"
AR_ENTRY_CONFIG ::= "\$config"

OPTION_ENVELOPE     ::= "envelope"
OPTION_OUTPUT       ::= "output"
OPTION_OUTPUT_SHORT ::= "o"

is_snapshot_bundle bits/ByteArray -> bool:
  catch: return SnapshotBundle.is_bundle_content bits
  return false

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
  root_cmd.add config_cmd
  root_cmd.run arguments

create_cmd -> cli.Command:
  return cli.Command "create"
      --options=[
          cli.OptionString "binary"
              --short_help="Set the binary input (e.g. firmware.bin)."
              --type="file"
              --required
      ]
      --run=:: create_envelope it

create_envelope parsed/cli.Parsed -> none:
  output_path := parsed[OPTION_ENVELOPE]
  input_path := parsed["binary"]

  // TODO(kasper): Do some sanity checks on the
  // structure of this. Can we check that we don't
  // already have stuff appended to the DROM section?
  binary_data := file.read_content input_path
  binary := Esp32Binary binary_data

  envelope := Envelope.create { AR_ENTRY_BINARY: binary_data }
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
          --options=[ option_output ]
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

container_install parsed/cli.Parsed -> none:
  name := parsed["name"]
  image_path := parsed["image"]
  if (name.index_of "\$") >= 0:
    throw "cannot install container with \$ in the name ('$name')"
  image_data := file.read_content image_path
  if not is_snapshot_bundle image_data:
    // We're not dealing with a snapshot, so make sure
    // the provided image is a valid relocatable image.
    out := bytes.Buffer
    output := BinaryRelocatedOutput out 0x12345678
    output.write WORD_SIZE image_data
    image_bits := out.bytes
    // TODO(kasper): Can we validate that the output
    // appears to be correct?
  update_envelope parsed: | files/Map |
    files[name] = image_data

container_uninstall parsed/cli.Parsed -> none:
  name := parsed["name"]
  update_envelope parsed: | files/Map |
    files.remove name

container_list parsed/cli.Parsed -> none:
  input_path := parsed[OPTION_ENVELOPE]
  entries := (Envelope.load input_path).entries
  output := {:}
  entries.do: | name/string content/ByteArray |
    if name.starts_with "\$": continue.do
    if is_snapshot_bundle content:
      bundle := SnapshotBundle name content
      output[name] = bundle.uuid.stringify
    else:
      // TODO(kasper): It would be ideal if we could print
      // the uuid of the image here.
      output[name] = "<relocatable image>"
  print (json.stringify output)

config_cmd -> cli.Command:
  cmd := cli.Command "config"

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
          --run=:: config_get it

  cmd.add
      cli.Command "remove"
          --options=[ option_output ]
          --rest=[ option_key_required ]
          --run=:: config_remove it

  cmd.add
      cli.Command "set"
          --options=[ option_output ]
          --rest=[ option_key_required, cli.OptionString "value" --multi --required ]
          --run=:: config_set it

  return cmd

config_get parsed/cli.Parsed -> none:
  input_path := parsed[OPTION_ENVELOPE]
  key := parsed["key"]

  entries := (Envelope.load input_path).entries
  entry := entries.get AR_ENTRY_CONFIG
  if not entry: return

  config := json.decode entry
  if key:
    if config.contains key:
      print (json.stringify (config.get key))
  else:
    print (json.stringify config)

config_remove parsed/cli.Parsed -> none:
  config_update parsed: | config/Map? key/string |
    if config: config.remove key

config_set parsed/cli.Parsed -> none:
  value := parsed["value"].map:
    // Try to parse this as a JSON value, but treat it
    // as a string if it fails.
    element := it
    catch: element = json.parse element
    element
  if value.size == 1: value = value.first
  config_update parsed: | config/Map? key/string |
    if key == "uuid":
      exception := catch: uuid.parse value
      if exception: throw "cannot parse uuid: $value ($exception)"
    config = config or {:}
    config[key] = value
    config

config_update parsed/cli.Parsed [block] -> none:
  key := parsed["key"]
  update_envelope parsed: | files/Map |
    config_data/ByteArray? := files.get AR_ENTRY_CONFIG
    config/Map? := config_data ? (json.decode config_data) : null
    config = block.call config key
    if config: files[AR_ENTRY_CONFIG] = json.encode config

extract_cmd -> cli.Command:
  return cli.Command "extract"
      --options=[
        cli.OptionString OPTION_OUTPUT
            --short_name=OPTION_OUTPUT_SHORT
            --short_help="Set the binary output (e.g. firmware.bin)."
            --type="file"
            --required,
      ]
      --run=:: extract_binary it

extract_binary parsed/cli.Parsed -> none:
  input_path := parsed[OPTION_ENVELOPE]
  output_path := parsed[OPTION_OUTPUT]

  binary/ByteArray? := null
  config/Map := {:}
  containers ::= {:}

  entries := (Envelope.load input_path).entries
  entries.do: | name/string content/ByteArray |
    if name == AR_ENTRY_BINARY:
      binary = content
    else if name == AR_ENTRY_CONFIG:
      config = json.decode content
    else if not name.starts_with "\$":
      containers[name] = content

  if not binary:
    throw "cannot find $AR_ENTRY_BINARY entry in envelope '$input_path'"

  system_uuid/uuid.Uuid? := null
  if config.contains "uuid":
    catch: system_uuid = uuid.parse (config.get "uuid")
    config = config.filter: it != "uuid"
  if not system_uuid:
    system_uuid = uuid.uuid5 "$random" "$Time.now".to_byte_array

  configured := inject_config config system_uuid binary
  binary_content := extract_binary_content
      --binary_input=configured
      --containers=containers
      --system_uuid=system_uuid

  out_stream := file.Stream.for_write output_path
  out_writer := writer.Writer out_stream
  out_writer.write binary_content
  out_stream.close

update_envelope parsed/cli.Parsed [block] -> none:
  input_path := parsed[OPTION_ENVELOPE]
  output_path := parsed[OPTION_OUTPUT]
  if not output_path: output_path = input_path

  entries := (Envelope.load input_path).entries
  block.call entries

  envelope := Envelope.create entries
  envelope.store output_path

extract_binary_content -> ByteArray
    --binary_input/ByteArray
    --containers/Map
    --system_uuid/uuid.Uuid:
  binary := Esp32Binary binary_input

  image_count := containers.size
  image_table := ByteArray 4 + 8 * image_count
  LITTLE_ENDIAN.put_uint32 image_table 0 image_count

  relocation_base := binary.extend_drom_address + image_table.size
  images := []
  index := 0
  containers.do: | name/string content/ByteArray |
    relocatable/ByteArray := ?
    if is_snapshot_bundle content:
      snapshot_bundle := SnapshotBundle name content
      program_id ::= snapshot_bundle.uuid
      program := snapshot_bundle.decode
      image := build_image program WORD_SIZE --system_uuid=system_uuid --program_id=program_id
      relocatable = image.build_relocatable
    else:
      relocatable = content
    out := bytes.Buffer
    output := BinaryRelocatedOutput out relocation_base
    output.write WORD_SIZE relocatable
    image_bits := out.bytes
    image_size := image_bits.size

    LITTLE_ENDIAN.put_uint32 image_table 4 + index * 8
        relocation_base
    LITTLE_ENDIAN.put_uint32 image_table 8 + index * 8
        image_size

    image_size_padded := round_up image_size 4
    image_bits += ByteArray (image_size_padded - image_size)
    images.add image_bits + (ByteArray image_size_padded - image_size)
    relocation_base += image_size_padded
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

  version_/int
  entries/Map ::= {:}

  constructor.load path/string:
    input_stream := file.Stream.for_read path
    reader := ar.ArReader input_stream
    version/int? := null
    while file := reader.next:
      if file.name == INFO_ENTRY_NAME:
        version = validate file.content
      else:
        entries[file.name] = file.content
    input_stream.close
    version_ = version

  constructor.create .entries:
    version_ = ENVELOPE_FORMAT_VERSION

  store path/string -> none:
    output_stream := file.Stream.for_write path
    writer := ar.ArWriter output_stream
    // Add the enveloper info entry.
    info := ByteArray INFO_ENTRY_SIZE
    LITTLE_ENDIAN.put_uint32 info INFO_ENTRY_MARKER_OFFSET MARKER
    LITTLE_ENDIAN.put_uint32 info INFO_ENTRY_VERSION_OFFSET version_
    writer.add INFO_ENTRY_NAME info
    // Add all other entries.
    entries.do: | name/string content/ByteArray |
      writer.add name content
    output_stream.close

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

class Esp32Binary:
  static MAGIC_OFFSET_         ::= 0
  static SEGMENT_COUNT_OFFSET_ ::= 1
  static HASH_APPENDED_OFFSET_ ::= 23
  static HEADER_SIZE_          ::= 24

  static ESP_CHECKSUM_MAGIC_   ::= 0xef

  static IROM_MAP_START ::= 0x400d0000
  static IROM_MAP_END   ::= 0x40400000
  static DROM_MAP_START ::= 0x3f400000
  static DROM_MAP_END   ::= 0x3f800000

  header_/ByteArray
  segments_/List

  constructor bits/ByteArray:
    header_ = bits[0..HEADER_SIZE_]
    // TODO(kasper): Validate magic.
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
    // This is a pretty serious padding up. We do it guarantee
    // that segments that follow this one do not change their
    // alignment within the individual flash pages, which seems
    // to be a requirement. It might be possible to get away with
    // less padding somehow.
    padded := round_up bits.size 64 * 1024
    bits = bits + (ByteArray padded - bits.size)
    // We look for the last DROM segment, because it will grow into
    // unused virtual memory, so we can extend that without relocating
    // other segments (which we don't know how to).
    drom := find_last_drom_segment_
    if not drom: throw "Cannot append to non-existing DROM segment"
    // Run through all the segments and extend the
    // segment we just found. All segments following
    // that one needs to be displaced in flash.
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
    segments_.do: | segment/Esp32BinarySegment |
      address := segment.address
      if not DROM_MAP_START <= address < DROM_MAP_END: continue.do
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

// These two are the current offsets of the config data in the system image.
// We could auto-detect them from the bin file, but they are only used files
// from the current SDK so there's no need.
IMAGE_DATA_SIZE ::= 1024
IMAGE_DATA_OFFSET ::= 296

IMAGE_DATA_MAGIC_1 ::= 0x7017da7a
IMAGE_DATA_MAGIC_2 ::= 0xc09f19

// The factory image contains an "empty" section of 1024 bytes where we encoded
// the config, so that the image can run completely independently.
inject_config config/Map unique_id/uuid.Uuid bits/ByteArray -> ByteArray:
  image_data_position := find_image_data_position bits
  image_data_offset := image_data_position[0]
  image_data_size := image_data_position[1]
  image_config_size := image_data_size - uuid.SIZE

  config_data := ubjson.encode config
  if config_data.size > image_data_size:
    throw "cannot inline config of $config_data.size bytes (too big)"

  bits.replace image_data_offset (ByteArray image_data_size)  // Zero out area.
  bits.replace image_data_offset config_data
  bits.replace image_data_offset + image_config_size unique_id.to_byte_array
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
