// Copyright (C) 2026 Toit contributors.

import crypto.sha256 show sha256
import encoding.hex
import encoding.json
import expect show *
import host.directory
import host.file
import ..tools.ec618.check-base-api as api

HEADER ::= "void CLOCK_mclkEnable(void);\n"

fixture root/string:
  directory.mkdir --recursive "$root/$(api.SDK)/chip"
  directory.mkdir --recursive "$root/toolchains/ec618/project/src"
  directory.mkdir --recursive "$root/toolchains/ec618/project/inc"
  file.write-contents HEADER --path="$root/$(api.SDK)/chip/clock.h"
  file.write-contents "  (const void*)&old_export,\n" --path="$root/$(api.KEEP)"
  document := {
    "header_directories": ["chip"],
    "excluded_headers": {:},
    "headers": {
      "chip/clock.h": {
        "sha256": hex.encode (sha256 HEADER.to-byte-array),
        "symbols": ["CLOCK_mclkEnable"],
        "excluded": {:},
      },
    },
  }
  file.write-contents (json.encode document) --path="$root/$(api.CONTRACT)"
  api.check-retention root --write

rejected expected/string [action]:
  error := catch: action.call
  expect error != null
  expect ("$error".contains expected)

main:
  root := directory.mkdtemp "/tmp/ec618-base-api-"
  try:
    fixture root
    required := api.check-retention root
    expect-equals 2 required.size
    api.check-exports required "00900000 T CLOCK_mclkEnable\n00900004 T old_export\n"
    api.check-exports required "00900000\tT\tCLOCK_mclkEnable\n00900004\tT\told_export\n"
    api.check-exports required "00900000 W CLOCK_mclkEnable\n00900004 V old_export\n"
    [
      "00900000 U CLOCK_mclkEnable",
      "00900000 w CLOCK_mclkEnable",
      "00900000 t CLOCK_mclkEnable",
      "not-an-address T CLOCK_mclkEnable",
      "00900000 unknown CLOCK_mclkEnable",
      "file.o: 00900000 T CLOCK_mclkEnable",
    ].do: |entry/string|
      rejected "lacks required exports: CLOCK_mclkEnable":
        api.check-exports required "$entry\n00900004 T old_export\n"
    rejected "lacks required exports: CLOCK_mclkEnable":
      api.check-exports required "00900004 T old_export\n"
    rejected "lacks required exports: old_export":
      api.check-exports required "00900000 T CLOCK_mclkEnable\n"
    // Undefined symbols and incomplete lines cannot satisfy the gate.
    rejected "lacks required exports":
      api.check-exports required "         U CLOCK_mclkEnable\nold_export\n"
    file.write-contents "void CLOCK_newAPI(void);\n" --path="$root/$(api.SDK)/chip/clock.h"
    rejected "header changed": api.check-retention root
    file.write-contents HEADER --path="$root/$(api.SDK)/chip/clock.h"
    file.write-contents "void start(void);\n" --path="$root/$(api.SDK)/chip/new_peripheral.h"
    rejected "New SDK headers": api.check-retention root
    file.delete "$root/$(api.SDK)/chip/new_peripheral.h"
    file.write-contents "" --path="$root/$(api.INCLUDE)"
    rejected "Stale peripheral_keep": api.check-retention root
    api.check-retention root --write
    api.check-retention root
    ["", "0abc", "a-b", "a b", "café"].do: expect (not (api.valid-symbol it))
    ["_", "CLOCK_mclkEnable", "a0"].do: expect (api.valid-symbol it)
    document := json.decode (file.read-contents "$root/$(api.CONTRACT)")
    document["headers"]["chip/clock.h"]["excluded"]["CLOCK_mclkEnable"] = "disabled"
    file.write-contents (json.encode document) --path="$root/$(api.CONTRACT)"
    rejected "Invalid exclusions": api.check-retention root
    document["headers"]["chip/clock.h"]["excluded"] = {:}
    document["excluded_headers"]["chip/unused.h"] = ""
    file.write-contents (json.encode document) --path="$root/$(api.CONTRACT)"
    rejected "require a reason": api.check-retention root
    // Regeneration must be deterministic, preserving symbol order in the
    // base and avoiding duplicate pointers for explicitly retained exports.
    document["excluded_headers"] = {:}
    document["headers"]["chip/clock.h"]["symbols"] = [
      "z_last", "CLOCK_mclkEnable", "A_first", "old_export",
    ]
    file.write-contents (json.encode document) --path="$root/$(api.CONTRACT)"
    api.check-retention root --write
    generated := (file.read-contents "$root/$(api.INCLUDE)").to-string
    expect (generated.ends-with "EC618_BASE_API(A_first)\nEC618_BASE_API(CLOCK_mclkEnable)\nEC618_BASE_API(z_last)\n")
    expect (not (generated.contains "EC618_BASE_API(old_export)"))
    expect-equals 4 (api.check-retention root).size
    print "EC618 base API gate: exports, header drift, retention and exclusions PASS"
  finally:
    directory.rmdir --recursive root
