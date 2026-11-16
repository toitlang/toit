// Copyright (C) 2026 Toit contributors.

import expect show *
import encoding.yaml
import host.file
import .partitions

document -> Map:
  return yaml.decode (file.read-contents DEFAULT-DESCRIPTOR-PATH)

reject message/string [mutate]:
  doc := document
  mutate.call doc
  error := catch: Partitions.from-document doc
  expect (error is string and error.contains message)

main:
  normal := Partitions.from-document document
  expect-equals FLASH-END (normal.entries.last.offset + normal.entries.last.size)
  Partitions.load "tests/hw/ec618/partitions-shifted.yaml"
  [null, [], "not a map"].do: |value|
    expect-throw "partition descriptor must be a map": Partitions.from-document value
  reject "unknown property": it["partitionz"] = []
  reject "must use schema": it["\$schema"] = "unknown"
  [null, "0x800000", -1, 0x900000, 0x800001].do: |value|
    reject "xip-offset": it["xip-offset"] = value
  [null, "partitions", [], (List 33: null)].do: |value|
    reject "partitions must be a list": it["partitions"] = value
  reject "entry must be a map": it["partitions"][0] = 42
  reject "unknown property": it["partitions"][0]["offest"] = 0
  [null, 3, "", "bad\u0000name", "1234567890123456", "éééééééé"].do: |value|
    reject "partition name": it["partitions"][0]["name"] = value
  reject "duplicate entry": it["partitions"][1]["name"] = "headers"
  reject "unknown partition type": it["partitions"][0]["type"] = "reserved"
  [null, "4096", 0, -4096, FLASH-END + SECTOR].do: |value|
    reject "size must be an integer": it["partitions"][0]["size"] = value
  [null, "0", -4096, FLASH-END].do: |value|
    reject "offset must be an integer": it["partitions"][0]["offset"] = value
  reject "gap or overlap": it["partitions"][0]["offset"] = SECTOR
  reject "not 4 KiB aligned": it["partitions"][0]["size"] = 1
  reject "extends beyond": it["partitions"].last["size"] = 2 * SECTOR
  reject "table covers": it["partitions"].remove-last
  reject "exactly one 'base'": it["partitions"][2]["type"] = "locked"
  reject "exactly one 'anchor'": it["partitions"][5]["name"] = "other"
  reject "exactly two VM slots": it["partitions"][7]["type"] = "free"
  reject "equal sizes": |doc|
    doc["partitions"][6]["size"] -= SECTOR
    doc["partitions"][7]["size"] += SECTOR
  reject "anchor must be two sectors": |doc|
    doc["partitions"][4]["size"] += SECTOR
    doc["partitions"][5]["size"] -= SECTOR
  reject "base-id must be one sector": |doc|
    doc["partitions"][3]["size"] += SECTOR
    doc["partitions"][4]["size"] -= SECTOR
  reject "data partition named 'registry'": it["partitions"][9]["type"] = "free"
  print "EC618 descriptors: structure, fields, names, coverage and boot geometry PASS"
