// Copyright (C) 2026 Toit contributors.
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

import encoding.json
import host.file

import .format as format
import .api as api
import .compact-allocator as compact-allocator
import .inspector as inspector
import .toit-model as toit-model
import .server as server
import .tdm1 as tdm1

main args/List:
  exception := catch: run args
  if exception:
    code := "$exception"
    print (json.stringify {"error": {"code": code, "message": code}})
    exit 1

run args/List -> none:
  if args.size == 1 and (args[0] == "--help" or args[0] == "-h"):
    print-usage
    return
  if args.size == 3 and args[0] == "import":
    capture := format.import-manifest args[1] args[2]
    print (json.stringify {
      "event": "imported",
      "capture-id": capture.id,
      "output": args[2],
      "regions": capture.regions.size,
      "completeness": capture.metadata["completeness"],
    })
    return
  if (args.size == 3 or args.size == 4) and args[0] == "import-tdm1":
    capture := tdm1.import-stream
        args[1]
        args[2]
        --metadata-path=(args.size == 4 ? args[3] : null)
    print (json.stringify {
      "event": "imported",
      "source-format": "TDM1",
      "capture-id": capture.id,
      "output": args[2],
      "regions": capture.regions.size,
      "completeness": capture.metadata["completeness"],
    })
    return
  if (args.size == 2 or args.size == 3) and args[0] == "serve":
    port := args.size == 3 ? int.parse args[2] : 0
    server.serve (format.load args[1]) port
    return
  if args.size == 2 and args[0] == "summary":
    print (json.stringify (api.capture-summary (format.load args[1])))
    return
  if args.size == 2 and args[0] == "runtime":
    print (json.stringify (api.runtime-detail (format.load args[1])))
    return
  if args.size == 2 and args[0] == "process-stacks":
    print (json.stringify (api.process-stacks-detail (format.load args[1])))
    return
  if args.size == 2 and args[0] == "variables":
    print (json.stringify (api.process-variables-detail (format.load args[1])))
    return
  if (args.size == 2 or args.size == 3) and args[0] == "memory-accounting":
    capture := format.load args[1]
    if args.size == 2:
      print (json.stringify (api.memory-accounting-detail capture))
      return
    layout/Map := json.decode (file.read-contents args[2])
    metadata := capture.metadata.copy
    metadata["runtime-layout"] = layout
    decoder := inspector.Inspector capture (toit-model.Interpretation metadata)
    print (json.stringify decoder.memory-accounting)
    return
  if args.size == 3 and args[0] == "allocator":
    capture := format.load args[1]
    layout/Map := json.decode (file.read-contents args[2])
    print (json.stringify (compact-allocator.decode capture layout))
    return
  if args.size == 4 and args[0] == "stack":
    capture := format.load args[1]
    address := format.parse-address args[2]
    program := format.parse-address args[3]
    print (json.stringify (api.stack-detail capture address program))
    return
  if args.size == 4 and args[0] == "symbolize":
    capture := format.load args[1]
    program := format.parse-address args[2]
    bci := int.parse args[3]
    print (json.stringify (api.program-bci-detail capture program bci))
    return
  if (args.size == 5 or args.size == 7) and args[0] == "heap":
    capture := format.load args[1]
    start := format.parse-address args[2]
    end := format.parse-address args[3]
    program := format.parse-address args[4]
    offset := args.size == 7 ? int.parse args[5] : 0
    limit := args.size == 7 ? int.parse args[6] : api.DEFAULT-LIMIT
    print (json.stringify (api.heap-census capture start end program offset limit))
    return
  if (args.size == 4 or args.size == 6) and args[0] == "edges":
    capture := format.load args[1]
    address := format.parse-address args[2]
    program := format.parse-address args[3]
    offset := args.size == 6 ? int.parse args[4] : 0
    limit := args.size == 6 ? int.parse args[5] : api.DEFAULT-LIMIT
    print (json.stringify
        api.object-edges-detail capture address program offset limit)
    return
  if (args.size == 4 or args.size == 7) and args[0] == "inspect":
    capture := format.load args[1]
    object-heap := format.parse-address args[2]
    address := format.parse-address args[3]
    depth := args.size == 7
        ? int.parse args[4]
        : api.DEFAULT-INSPECTION-DEPTH
    max-objects := args.size == 7
        ? int.parse args[5]
        : api.DEFAULT-INSPECTION-OBJECTS
    max-elements := args.size == 7
        ? int.parse args[6]
        : api.DEFAULT-INSPECTION-ELEMENTS
    print (json.stringify
        api.inspect-object-detail
            capture
            object-heap
            address
            depth
            max-objects
            max-elements)
    return
  if (args.size == 6 or args.size == 8) and args[0] == "retainers":
    capture := format.load args[1]
    start := format.parse-address args[2]
    end := format.parse-address args[3]
    program := format.parse-address args[4]
    target := format.parse-address args[5]
    offset := args.size == 8 ? int.parse args[6] : 0
    limit := args.size == 8 ? int.parse args[7] : api.DEFAULT-LIMIT
    print (json.stringify
        api.direct-retainers capture start end program target offset limit)
    return
  if (args.size == 4 or args.size == 6) and args[0] == "path":
    capture := format.load args[1]
    object-heap := format.parse-address args[2]
    target := format.parse-address args[3]
    max-nodes := args.size == 6 ? int.parse args[4] : 10_000
    max-depth := args.size == 6 ? int.parse args[5] : 256
    print (json.stringify
        api.process-retention-path
            capture
            object-heap
            target
            max-nodes
            max-depth)
    return
  if (args.size == 4 or args.size == 7) and args[0] == "retained":
    capture := format.load args[1]
    object-heap := format.parse-address args[2]
    target := format.parse-address args[3]
    max-nodes := args.size == 7 ? int.parse args[4] : 10_000
    offset := args.size == 7 ? int.parse args[5] : 0
    limit := args.size == 7 ? int.parse args[6] : api.DEFAULT-LIMIT
    print (json.stringify
        api.process-retained-size
            capture
            object-heap
            target
            max-nodes
            offset
            limit)
    return
  if (args.size == 4 or args.size == 7) and args[0] == "transitive":
    capture := format.load args[1]
    object-heap := format.parse-address args[2]
    target := format.parse-address args[3]
    max-nodes := args.size == 7 ? int.parse args[4] : 10_000
    offset := args.size == 7 ? int.parse args[5] : 0
    limit := args.size == 7 ? int.parse args[6] : api.DEFAULT-LIMIT
    print (json.stringify
        api.process-transitive-size
            capture
            object-heap
            target
            max-nodes
            offset
            limit)
    return
  print-usage
  throw "INVALID_ARGUMENTS"

print-usage:
  print "Usage:"
  print "  device-inspector import MANIFEST.json OUTPUT.toitdump"
  print "  device-inspector import-tdm1 UART.bin OUTPUT.toitdump [METADATA.json]"
  print "  device-inspector serve CAPTURE.toitdump [PORT]"
  print "  device-inspector summary CAPTURE.toitdump"
  print "  device-inspector runtime CAPTURE.toitdump"
  print "  device-inspector process-stacks CAPTURE.toitdump"
  print "  device-inspector variables CAPTURE.toitdump"
  print "  device-inspector memory-accounting CAPTURE.toitdump [RUNTIME_LAYOUT.json]"
  print "  device-inspector allocator CAPTURE.toitdump RUNTIME_LAYOUT.json"
  print "  device-inspector stack CAPTURE.toitdump ADDRESS PROGRAM"
  print "  device-inspector symbolize CAPTURE.toitdump PROGRAM BCI"
  print "  device-inspector heap CAPTURE.toitdump START END PROGRAM [OFFSET LIMIT]"
  print "  device-inspector edges CAPTURE.toitdump ADDRESS PROGRAM [OFFSET LIMIT]"
  print "  device-inspector inspect CAPTURE.toitdump OBJECT_HEAP OBJECT [DEPTH MAX_OBJECTS MAX_ELEMENTS]"
  print "  device-inspector retainers CAPTURE.toitdump START END PROGRAM TARGET [OFFSET LIMIT]"
  print "  device-inspector path CAPTURE.toitdump OBJECT_HEAP TARGET [MAX_NODES MAX_DEPTH]"
  print "  device-inspector retained CAPTURE.toitdump OBJECT_HEAP TARGET [MAX_NODES OFFSET LIMIT]"
  print "  device-inspector transitive CAPTURE.toitdump OBJECT_HEAP TARGET [MAX_NODES OFFSET LIMIT]"
