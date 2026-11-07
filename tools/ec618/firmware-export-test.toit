// Copyright (C) 2026 Toit contributors.

import expect show *
import crypto.sha256 show sha256
import encoding.json
import encoding.ubjson
import host.file
import io show LITTLE-ENDIAN
import .slot-reloc
import ..firmware.ec618 as image

main args:
  if args.size != 4: throw "Usage: firmware-export-test.toit <description> <binary> <config.json> <vm-data>"
  description := ubjson.decode (file.read-contents args[0])
  binary := file.read-contents args[1]
  expect binary == description["binary"]
  expect-equals (sha256 binary) description["checksum"]
  length := LITTLE-ENDIAN.uint32 binary 0
  table := SlotRelocTable.parse binary[4..4 + length]
  body-end := 4 + length + table.body-size
  expect-equals binary.size (body-end + table.data-size)
  parts/List := description["parts"]
  types := ["binary", "images", "config"]
  if table.data-size != 0: types.add "data"
  expect-equals types (parts.map: it["type"])
  position := 0
  parts.do: |part/Map|
    expect-equals position part["from"]
    expect part["to"] > position
    expect part["to"] <= binary.size
    position = part["to"]
  expect-equals binary.size position
  expect-equals body-end parts[2]["to"]
  config-from := parts[2]["from"]
  config-size := LITTLE-ENDIAN.uint32 binary config-from
  expect-equals body-end (config-from + 4 + config-size)
  expect-equals (ubjson.encode (json.decode (file.read-contents args[2])))
      binary[config-from + 4..body-end]
  expect-equals (file.read-contents args[3]) binary[body-end..]
  invalid := binary.copy
  invalid[parts[1]["from"]] ^= 1
  expect-throw "invalid EC618 extension magic": image.parts invalid
  invalid = binary.copy
  LITTLE-ENDIAN.put-uint32 invalid (parts[1]["from"] + 4) binary.size
  expect-throw "invalid EC618 extension/config boundary": image.parts invalid
  invalid = binary.copy
  LITTLE-ENDIAN.put-uint32 invalid config-from (config-size + 1)
  expect-throw "EC618 config length does not match the canonical body": image.parts invalid
  expect-throw "EC618 canonical length does not match its relocation table": image.parts binary[..binary.size - 1]
  print "EC618 export: canonical identity, coverage, config, VM data and separate SHA-256 PASS"
