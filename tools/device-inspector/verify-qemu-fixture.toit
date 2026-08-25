// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.json

import .api as api
import .format as format

main args/List:
  if args.size != 1: throw "EXPECTED_CAPTURE_PATH"
  capture := format.load args[0]
  decoded := api.runtime-detail capture
  selected/Map? := null
  decoded["process-groups"].do: | group/Map |
    group["processes"].do: | process/Map |
      if group["id"] == 2: selected = process
  if not selected: throw "FIXTURE_PROCESS_NOT_FOUND"

  heap/Map := selected["object-heap"]
  old-space/Map := heap["old-space"]
  census/Map := old-space["census"]
  if census["object-count"] <= 0: throw "FIXTURE_OLD_SPACE_EMPTY"

  marker/Map? := null
  heap["globals"]["items"].do: | global/Map |
    if (global.get "qualified-name") == "old-space-marker": marker = global
  if not marker: throw "FIXTURE_MARKER_GLOBAL_NOT_FOUND"
  marker-address-value := marker.get "object-address"
  if not marker-address-value: throw "FIXTURE_MARKER_IS_NOT_REFERENCE"
  marker-address := format.parse-address marker-address-value

  marker-is-old := false
  old-space["chunks"].do: | chunk/Map |
    start := format.parse-address chunk["start"]
    end := format.parse-address chunk["end"]
    if marker-address >= start and marker-address < end: marker-is-old = true
  if not marker-is-old: throw "FIXTURE_MARKER_NOT_IN_OLD_SPACE"

  accounting := api.memory-accounting-detail capture
  wifi-tag/Map? := null
  accounting["allocation-tag-catalog"].do: | tag/Map |
    if tag["name"] == "wifi": wifi-tag = tag
  if not wifi-tag: throw "FIXTURE_WIFI_TAG_NOT_FOUND"
  if wifi-tag["bytes"] <= 0: throw "FIXTURE_WIFI_BYTES_EMPTY"
  if wifi-tag["allocation-count"] <= 0: throw "FIXTURE_WIFI_ALLOCATIONS_EMPTY"

  print (json.stringify {
    "event": "device-inspector-fixture-verified",
    "capture-id": capture.id,
    "process-id": selected["id"],
    "old-space-object-count": census["object-count"],
    "old-space-object-bytes": census["object-bytes"],
    "marker": marker-address-value,
    "wifi-bytes": wifi-tag["bytes"],
    "wifi-allocation-count": wifi-tag["allocation-count"],
  })
