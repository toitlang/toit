// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import encoding.base64
import encoding.json
import host.directory
import host.file
import http
import net
import net.modules.tcp

import ..format as format
import ..server as inspector-server

main:
  tmp := directory.mkdtemp "/tmp/toit-device-inspector-server-"
  try:
    file.write-contents --path="$tmp/dram.bin" #[1, 2, 3, 4]
    file.write-contents --path="$tmp/target.json" "{}"
    file.write-contents --path="$tmp/manifest.json" """
      {
        "target":{"word-size":4,"endianness":"little"},
        "completeness":{"state":"partial"},
        "provenance":{"acquisition":"server-test"},
        "attachments":[{"id":"layout","kind":"gdb-target-description","file":"target.json"}],
        "register-sets":[{"core":0,"thread-id":"1","architecture":"xtensa","encoding":"gdb-remote-register-packet","data":"0102xxxx","layout-attachment-id":"layout"}],
        "regions":[{"id":"dram","name":"<script>bad()</script>","address":"0x1000","size":4,"file":"dram.bin"}]
      }
      """
    capture := format.import-manifest "$tmp/manifest.json" "$tmp/test.toitdump"
    network := net.open
    socket := tcp.TcpServerSocket network
    socket.listen "127.0.0.1" 0
    port := socket.local-address.port
    http-server := http.Server --max-tasks=4
    task --background::
      http-server.listen socket:: | request/http.RequestIncoming writer/http.ResponseWriter |
        inspector-server.handle capture request writer

    client := http.Client network
    index-response := client.get --uri="http://127.0.0.1:$port/"
    expect-equals 200 index-response.status-code
    index := index-response.body.read-all.to-string
    expect (index.contains "Processes and stacks")
    expect (index.contains "Human-readable values")
    expect (index.contains "Show physical stack placement")
    expect (index.contains "Parameters")
    expect (index.contains "Locals")
    expect (index.contains "Operands")
    expect (index.contains "Stack blocks")
    expect (index.contains "VM control state")
    expect (index.contains "pending parameter")
    expect (index.contains "Keeps RAM alive")
    expect (index.contains "Inspect variables")
    expect (index.contains "renderProcessVariables")
    expect (index.contains "named parameters and locals")
    expect (index.contains "System memory accounting")
    expect (index.contains "Modeled memory by current owner")
    expect (index.contains "Firmware static and reserved regions")
    expect (index.contains "Static/reserved totals remain limited")
    expect (index.contains "Allocator tag coverage")
    expect (index.contains "Ownership-root coverage")
    expect (index.contains "Allocation ownership evidence")
    expect (index.contains "Allocation tags describe where memory was allocated")
    expect (index.contains "renderAllocationEvidence")
    expect (index.contains "limited to 250")
    expect (index.contains "Toit heap breakdown")
    expect (index.contains "Runtime phase:")
    expect (index.contains "GC view")
    expect (index.contains "GC liveness")
    expect (index.contains "Normal reachability and retained-size actions are disabled")
    expect (index.contains "View details")
    expect (index.contains "Classes")
    expect (index.contains "Objects")
    expect (index.contains "Previous")
    expect (index.contains "Next")
    expect (index.contains "Compute retained")
    expect (index.contains "Compute transitive")
    expect (index.contains "including objects shared with other roots")
    expect (index.contains "Find root path")
    expect (index.contains "Root path")
    expect (index.contains "Container")
    expect (index.contains "Not a live object")
    expect (index.contains
        "Not reachable from decoded strong roots; retained size is unavailable")
    expect (index.contains "PAGE_SIZE = 50")
    page-size-position := index.index-of "const PAGE_SIZE = 50;"
    startup-position := index.index-of "(async () => {"
    expect (page-size-position < startup-position)
    expect-not (index.contains "innerHTML")
    expect-not (index.contains "<script>bad()</script>")
    discovery := get-json client "http://127.0.0.1:$port/api/v1"
    expect-equals "v1" discovery["api-version"]
    expect (discovery["capabilities"].contains "stack-frame-slot-decoding")
    expect (discovery["capabilities"].contains "bytecode-operand-role-decoding")
    expect (discovery["capabilities"].contains "stack-control-state-decoding")
    expect (discovery["capabilities"].contains "stack-frame-symbolization")
    expect (discovery["capabilities"].contains "program-bci-symbolization")
    expect (discovery["capabilities"].contains "source-variable-decoding")
    expect (discovery["capabilities"].contains "process-stack-discovery")
    expect (discovery["capabilities"].contains "global-variable-decoding")
    expect (discovery["capabilities"].contains "storage-region-classification")
    expect (discovery["capabilities"].contains "block-reference-decoding")
    expect (discovery["capabilities"].contains "human-value-rendering")
    expect (discovery["capabilities"].contains "heap-range-census")
    expect (discovery["capabilities"].contains "object-edge-decoding")
    expect (discovery["capabilities"].contains "bounded-object-inspection")
    expect (discovery["capabilities"].contains "object-heap-program-inference")
    expect (discovery["capabilities"].contains "semantic-collection-inspection")
    expect (discovery["capabilities"].contains "direct-retainer-search")
    expect (discovery["capabilities"].contains "retention-path-search")
    expect (discovery["capabilities"].contains "retained-size-analysis")
    expect (discovery["capabilities"].contains "transitive-size-analysis")
    expect (discovery["capabilities"].contains "component-memory-accounting")
    expect (discovery["capabilities"].contains "typed-ownership-roots")
    expect (discovery["capabilities"].contains "full-device-native-root-discovery")
    expect (discovery["capabilities"].contains "gc-metadata-ownership")
    expect (discovery["capabilities"].contains "gc-spare-space-ownership")
    expect (discovery["capabilities"].contains "allocator-heap-backing-ownership")
    expect (discovery["capabilities"].contains "toit-scheduler-thread-ownership")
    expect (discovery["capabilities"].contains "freertos-task-root-discovery")
    expect (discovery["capabilities"].contains "event-source-root-discovery")
    expect (discovery["capabilities"].contains "reserved-allocator-capacity-accounting")
    expect (discovery["capabilities"].contains "firmware-physical-region-accounting")
    expect (discovery["capabilities"].contains "newlib-stdio-root-discovery")
    expect (discovery["capabilities"].contains "gpio-static-root-discovery")
    expect (discovery["capabilities"].contains "firmware-static-root-discovery")
    expect (discovery["capabilities"].contains "leak-candidate-classification")
    memory := get-json client "http://127.0.0.1:$port/api/v1/captures/$(capture.id)/memory?address=0x1001&length=2"
    expect-equals (base64.encode #[2, 3]) memory["data"]
    search := get-json client "http://127.0.0.1:$port/api/v1/captures/$(capture.id)/memory/search?hex=0203"
    expect-equals "0x1001" search["matches"][0]["address"]
    word := get-json client "http://127.0.0.1:$port/api/v1/captures/$(capture.id)/words/0x1000"
    expect-equals "heap-reference" word["candidate-kind"]
    object := get-json client "http://127.0.0.1:$port/api/v1/captures/$(capture.id)/objects/0x1000"
    expect-equals "forwarded" object["state"]
    response := client.get --uri="http://127.0.0.1:$port/api/v1/captures/$(capture.id)/memory?address=0xfff&length=2"
    expect-equals 416 response.status-code
    error/Map := json.decode (response.body.read-all)
    expect-equals "ADDRESS_NOT_CAPTURED" error["error"]["code"]
    attachments := get-json client "http://127.0.0.1:$port/api/v1/captures/$(capture.id)/attachments"
    expect-equals 1 attachments["total"]
    register-page := get-json client "http://127.0.0.1:$port/api/v1/captures/$(capture.id)/register-sets"
    expect-equals 1 register-page["total"]
    expect-equals null (register-page["items"][0].get "data")
    register := get-json client "http://127.0.0.1:$port/api/v1/captures/$(capture.id)/register-sets/core-0"
    expect-equals "0102xxxx" register["data"]
    runtime-response := client.get --uri="http://127.0.0.1:$port/api/v1/captures/$(capture.id)/runtime"
    expect-equals 409 runtime-response.status-code
    accounting-response := client.get --uri="http://127.0.0.1:$port/api/v1/captures/$(capture.id)/memory-accounting"
    expect-equals 409 accounting-response.status-code
    process-stacks-response := client.get --uri="http://127.0.0.1:$port/api/v1/captures/$(capture.id)/process-stacks"
    expect-equals 409 process-stacks-response.status-code
    process-variables-response := client.get --uri="http://127.0.0.1:$port/api/v1/captures/$(capture.id)/process-variables"
    expect-equals 409 process-variables-response.status-code
    symbolize-response := client.get --uri="http://127.0.0.1:$port/api/v1/captures/$(capture.id)/symbolize?program=0x2000&bci=8"
    expect-equals 409 symbolize-response.status-code
    stack-response := client.get --uri="http://127.0.0.1:$port/api/v1/captures/$(capture.id)/stacks/0x1000?program=0x2000"
    expect-equals 409 stack-response.status-code
    heap-response := client.get --uri="http://127.0.0.1:$port/api/v1/captures/$(capture.id)/heap-census?start=0x1000&end=0x1004&program=0x2000"
    expect-equals 409 heap-response.status-code
    invalid-space-response := client.get --uri="http://127.0.0.1:$port/api/v1/captures/$(capture.id)/heap-census?start=0x1000&end=0x1004&program=0x2000&space-kind=invalid"
    expect-equals 400 invalid-space-response.status-code
    edges-response := client.get --uri="http://127.0.0.1:$port/api/v1/captures/$(capture.id)/objects/0x1000/edges?program=0x2000"
    expect-equals 409 edges-response.status-code
    inspect-response := client.get --uri="http://127.0.0.1:$port/api/v1/captures/$(capture.id)/objects/0x1000/inspect?object-heap=0x1000"
    expect-equals 409 inspect-response.status-code
    retainers-response := client.get --uri="http://127.0.0.1:$port/api/v1/captures/$(capture.id)/retainers?start=0x1000&end=0x1004&program=0x2000&target=0x1000"
    expect-equals 409 retainers-response.status-code
    path-response := client.get --uri="http://127.0.0.1:$port/api/v1/captures/$(capture.id)/retention-path?object-heap=0x1000&target=0x1000"
    expect-equals 409 path-response.status-code
    retained-response := client.get --uri="http://127.0.0.1:$port/api/v1/captures/$(capture.id)/retained-size?object-heap=0x1000&target=0x1000"
    expect-equals 409 retained-response.status-code
    transitive-response := client.get --uri="http://127.0.0.1:$port/api/v1/captures/$(capture.id)/transitive-size?object-heap=0x1000&target=0x1000"
    expect-equals 409 transitive-response.status-code
    client.close
    http-server.close
    socket.close
  finally:
    directory.rmdir --recursive tmp

get-json client/http.Client uri/string -> Map:
  response := client.get --uri=uri
  expect-equals 200 response.status-code
  return json.decode (response.body.read-all)
