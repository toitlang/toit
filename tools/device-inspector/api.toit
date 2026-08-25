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

import encoding.base64

import .format as format
import .inspector as inspector
import .toit-model as toit-model

API-VERSION ::= "v1"
DEFAULT-LIMIT ::= 100
MAX-LIMIT ::= 500
MAX-MEMORY-READ ::= 65_536
DEFAULT-INSPECTION-DEPTH ::= 2
DEFAULT-INSPECTION-OBJECTS ::= 100
DEFAULT-INSPECTION-ELEMENTS ::= 100

discovery capture/format.Capture -> Map:
  return {
    "api-version": API-VERSION,
    "artifact-format-version": format.FORMAT-VERSION,
    "capabilities": [
      "capture-metadata",
      "region-list",
      "bounded-memory-read",
      "external-attachment-identities",
      "per-core-register-sets",
      "tagged-word-decoding",
      "object-header-decoding",
      "stack-frame-slot-decoding",
      "bytecode-operand-role-decoding",
      "stack-control-state-decoding",
      "stack-frame-symbolization",
      "program-bci-symbolization",
      "source-variable-decoding",
      "process-stack-discovery",
      "global-variable-decoding",
      "storage-region-classification",
      "block-reference-decoding",
      "human-value-rendering",
      "component-memory-accounting",
      "typed-ownership-roots",
      "full-device-native-root-discovery",
      "gc-metadata-ownership",
      "gc-spare-space-ownership",
      "allocator-heap-backing-ownership",
      "toit-scheduler-thread-ownership",
      "freertos-task-root-discovery",
      "event-source-root-discovery",
      "reserved-allocator-capacity-accounting",
      "firmware-physical-region-accounting",
      "newlib-stdio-root-discovery",
      "gpio-static-root-discovery",
      "firmware-static-root-discovery",
      "leak-candidate-classification",
      "heap-range-census",
      "object-edge-decoding",
      "bounded-object-inspection",
      "object-heap-program-inference",
      "semantic-collection-inspection",
      "direct-retainer-search",
      "retention-path-search",
      "retained-size-analysis",
      "transitive-size-analysis",
      "bounded-byte-search",
      "runtime-discovery",
      "gc-phase-classification",
      "gc-mark-bit-liveness",
      "phase-aware-heap-census",
      "envelope-inspector-description",
      "versioned-native-ownership-description",
    ],
    "limits": {
      "default-page-size": DEFAULT-LIMIT,
      "max-page-size": MAX-LIMIT,
      "max-memory-read": MAX-MEMORY-READ,
      "max-object-inspection-depth": 8,
      "max-object-inspection-objects": 500,
      "max-object-inspection-elements": 500,
    },
    "links": {
      "self": "/api/v1",
      "openapi": "/api/v1/openapi.json",
      "captures": "/api/v1/captures",
      "capture": "/api/v1/captures/$(capture.id)",
    },
  }

capture-summary capture/format.Capture -> Map:
  attachments/List := capture.metadata.get "attachments" --if-absent=: []
  register-sets/List := capture.metadata.get "register-sets" --if-absent=: []
  program-layouts/List := capture.metadata.get "program-layouts" --if-absent=: []
  result := {
    "id": capture.id,
    "target": capture.metadata["target"],
    "completeness": capture.metadata["completeness"],
    "provenance": capture.metadata["provenance"],
    "region-count": capture.regions.size,
    "attachment-count": attachments.size,
    "register-set-count": register-sets.size,
    "program-layout-count": program-layouts.size,
    "links": {
      "self": "/api/v1/captures/$(capture.id)",
      "regions": "/api/v1/captures/$(capture.id)/regions",
      "memory": "/api/v1/captures/$(capture.id)/memory{?address,length}",
      "attachments": "/api/v1/captures/$(capture.id)/attachments",
      "register-sets": "/api/v1/captures/$(capture.id)/register-sets",
      "runtime": "/api/v1/captures/$(capture.id)/runtime",
      "process-stacks": "/api/v1/captures/$(capture.id)/process-stacks",
      "process-variables": "/api/v1/captures/$(capture.id)/process-variables",
      "symbolize-bci": "/api/v1/captures/$(capture.id)/symbolize{?program,bci}",
      "memory-accounting": "/api/v1/captures/$(capture.id)/memory-accounting",
      "stack": "/api/v1/captures/$(capture.id)/stacks/{address}{?program}",
      "heap-census": "/api/v1/captures/$(capture.id)/heap-census{?start,end,program,space-kind,offset,limit}",
      "object-edges": "/api/v1/captures/$(capture.id)/objects/{address}/edges{?program,offset,limit}",
      "inspect-object": "/api/v1/captures/$(capture.id)/objects/{address}/inspect{?object-heap,depth,max-objects,max-elements}",
      "retainers": "/api/v1/captures/$(capture.id)/retainers{?start,end,program,target,offset,limit}",
      "retention-path": "/api/v1/captures/$(capture.id)/retention-path{?object-heap,target,max-nodes,max-depth}",
      "retained-size": "/api/v1/captures/$(capture.id)/retained-size{?object-heap,target,max-nodes,offset,limit}",
      "transitive-size": "/api/v1/captures/$(capture.id)/transitive-size{?object-heap,target,max-nodes,offset,limit}",
    },
  }
  if capture.metadata.contains "capture-scope":
    result["capture-scope"] = capture.metadata["capture-scope"]
  inspector-description/Map? := capture.metadata.get "inspector-description"
  if inspector-description:
    firmware/Map := inspector-description["firmware"]
    ownership/Map := inspector-description["native-ownership"]
    result["inspector-description"] = {
      "format-version": inspector-description["format-version"],
      "generator": inspector-description["generator"],
      "firmware-elf-sha256": firmware["elf-sha256"],
      "native-ownership-format-version": ownership["format-version"],
      "source-envelope-attachment-id": inspector-description.get
          "source-envelope-attachment-id",
    }
  return result

capture-detail capture/format.Capture -> Map:
  result := capture-summary capture
  result["format"] = capture.metadata["format"]
  result["format-version"] = capture.metadata["format-version"]
  return result

regions-page capture/format.Capture offset/int limit/int -> Map:
  if offset < 0: throw "INVALID_OFFSET"
  if limit <= 0 or limit > MAX-LIMIT: throw "INVALID_LIMIT"
  end := min capture.regions.size (offset + limit)
  items := []
  if offset < capture.regions.size:
    capture.regions[offset..end].do: | region/format.Region |
      item := region.metadata
      item["links"] = {
        "self": "/api/v1/captures/$(capture.id)/regions/$(region.id)",
      }
      items.add item
  next-offset := end < capture.regions.size ? end : null
  return {
    "items": items,
    "offset": offset,
    "limit": limit,
    "total": capture.regions.size,
    "next-offset": next-offset,
  }

region-detail capture/format.Capture id/string -> Map:
  capture.regions.do: | region/format.Region |
    if region.id == id:
      return region.metadata
  throw "REGION_NOT_FOUND"

attachments-page capture/format.Capture offset/int limit/int -> Map:
  attachments/List := capture.metadata.get "attachments" --if-absent=: []
  return list-page attachments offset limit

attachment-detail capture/format.Capture id/string -> Map:
  attachments/List := capture.metadata.get "attachments" --if-absent=: []
  attachments.do: | attachment/Map |
    if attachment["id"] == id: return attachment
  throw "ATTACHMENT_NOT_FOUND"

register-sets-page capture/format.Capture offset/int limit/int -> Map:
  register-sets/List := capture.metadata.get "register-sets" --if-absent=: []
  summaries := register-sets.map: | entry/Map |
    result := {
      "id": entry["id"],
      "core": entry["core"],
      "thread-id": entry["thread-id"],
      "architecture": entry["architecture"],
      "byte-order": entry["byte-order"],
      "encoding": entry["encoding"],
      "source": entry["source"],
      "metadata": entry["metadata"],
    }
    if entry.contains "data":
      result["encoded-size"] = entry["data"].size
      result["layout-attachment-id"] = entry["layout-attachment-id"]
    if entry.contains "values":
      result["value-count"] = entry["values"].size
      if entry.contains "source-attachment-id":
        result["source-attachment-id"] = entry["source-attachment-id"]
    result
  return list-page summaries offset limit

register-set-detail capture/format.Capture id/string -> Map:
  register-sets/List := capture.metadata.get "register-sets" --if-absent=: []
  register-sets.do: | entry/Map |
    if entry["id"] == id: return entry
  throw "REGISTER_SET_NOT_FOUND"

list-page items/List offset/int limit/int -> Map:
  if offset < 0: throw "INVALID_OFFSET"
  if limit <= 0 or limit > MAX-LIMIT: throw "INVALID_LIMIT"
  end := min items.size (offset + limit)
  page := offset < items.size ? items[offset..end] : []
  return {
    "items": page,
    "offset": offset,
    "limit": limit,
    "total": items.size,
    "next-offset": end < items.size ? end : null,
  }

memory-read capture/format.Capture address/int length/int -> Map:
  if length <= 0 or length > MAX-MEMORY-READ: throw "INVALID_LENGTH"
  data := capture.read address length
  return {
    "address": format.hex-address address,
    "length": length,
    "encoding": "base64",
    "data": base64.encode data,
  }

word-detail capture/format.Capture address/int -> Map:
  return (capture-inspector capture).word address

object-detail capture/format.Capture address/int program/int?=null -> Map:
  return (capture-inspector capture).object address program

object-edges-detail
    capture/format.Capture address/int program/int offset/int limit/int
    -> Map:
  return (capture-inspector capture).object-edges address program offset limit

inspect-object-detail
    capture/format.Capture object-heap/int address/int
    depth/int=DEFAULT-INSPECTION-DEPTH
    max-objects/int=DEFAULT-INSPECTION-OBJECTS
    max-elements/int=DEFAULT-INSPECTION-ELEMENTS
    -> Map:
  return (capture-inspector capture).inspect-object
      object-heap
      address
      depth
      max-objects
      max-elements

direct-retainers
    capture/format.Capture start/int end/int program/int target/int
    offset/int limit/int
    -> Map:
  decoder := capture-inspector capture
  return decoder.direct-retainers start end program target offset limit

process-retention-path
    capture/format.Capture object-heap/int target/int max-nodes/int max-depth/int
    -> Map:
  decoder := capture-inspector capture
  return decoder.retention-path object-heap target max-nodes max-depth

process-retained-size
    capture/format.Capture object-heap/int target/int max-nodes/int
    offset/int limit/int
    -> Map:
  decoder := capture-inspector capture
  return decoder.retained-size object-heap target max-nodes offset limit

process-transitive-size
    capture/format.Capture object-heap/int target/int max-nodes/int
    offset/int limit/int
    -> Map:
  decoder := capture-inspector capture
  return decoder.transitive-size object-heap target max-nodes offset limit

stack-detail capture/format.Capture address/int program/int -> Map:
  return (capture-inspector capture).stack address program

memory-search capture/format.Capture pattern/ByteArray limit/int -> Map:
  return (capture-inspector capture).search pattern limit

heap-census
    capture/format.Capture start/int end/int program/int offset/int limit/int
    --space-kind/string?=null
    -> Map:
  decoder := capture-inspector capture
  return decoder.heap-census
      start
      end
      program
      offset
      limit
      --space-kind=space-kind

runtime-detail capture/format.Capture -> Map:
  return (capture-inspector capture).runtime

process-stacks-detail capture/format.Capture -> Map:
  return (capture-inspector capture).process-variables

process-variables-detail capture/format.Capture -> Map:
  return process-stacks-detail capture

program-bci-detail capture/format.Capture program/int bci/int -> Map:
  if bci < 0: throw "INVALID_BCI"
  return (capture-inspector capture).symbolize-bci program bci

memory-accounting-detail capture/format.Capture -> Map:
  return (capture-inspector capture).memory-accounting

capture-inspector capture/format.Capture -> inspector.Inspector:
  interpretation := toit-model.Interpretation capture.metadata
  return inspector.Inspector capture interpretation

openapi -> Map:
  return {
    "openapi": "3.1.0",
    "info": {
      "title": "Toit device inspector API",
      "version": API-VERSION,
    },
    "servers": [{"url": "/"}],
    "paths": {
      "/api/v1": {"get": {"summary": "Discover API capabilities", "responses": {"200": {"description": "API discovery"}}}},
      "/api/v1/openapi.json": {"get": {"summary": "Read this OpenAPI document", "responses": {"200": {"description": "OpenAPI document"}}}},
      "/api/v1/captures": {"get": {"summary": "List loaded captures", "responses": {"200": {"description": "Capture page"}}}},
      "/api/v1/captures/{captureId}": {
        "parameters": [CAPTURE-ID-PARAMETER_],
        "get": {"summary": "Read capture metadata", "responses": {"200": {"description": "Capture metadata"}}},
      },
      "/api/v1/captures/{captureId}/regions": {
        "parameters": [CAPTURE-ID-PARAMETER_],
        "get": {
          "summary": "List captured memory regions",
          "parameters": [
            {"name": "offset", "in": "query", "schema": {"type": "integer", "minimum": 0}},
            {"name": "limit", "in": "query", "schema": {"type": "integer", "minimum": 1, "maximum": MAX-LIMIT}},
          ],
          "responses": {"200": {"description": "Region page"}},
        },
      },
      "/api/v1/captures/{captureId}/regions/{regionId}": {
        "parameters": [
          CAPTURE-ID-PARAMETER_,
          {"name": "regionId", "in": "path", "required": true, "schema": {"type": "string"}},
        ],
        "get": {"summary": "Read captured region metadata", "responses": {"200": {"description": "Region metadata"}}},
      },
      "/api/v1/captures/{captureId}/memory": {
        "parameters": [CAPTURE-ID-PARAMETER_],
        "get": {
          "summary": "Read a bounded range contained in one captured region",
          "parameters": [
            {"name": "address", "in": "query", "required": true, "schema": {"type": "string", "pattern": "^0x[0-9a-fA-F]+\$"}},
            {"name": "length", "in": "query", "schema": {"type": "integer", "minimum": 1, "maximum": MAX-MEMORY-READ}},
          ],
          "responses": {
            "200": {"description": "Base64-encoded memory range"},
            "416": {"description": "Address range was not captured"},
          },
        },
      },
      "/api/v1/captures/{captureId}/memory/search": {
        "parameters": [CAPTURE-ID-PARAMETER_],
        "get": {"summary": "Search captured regions for a bounded hexadecimal byte pattern", "responses": {"200": {"description": "Matching virtual addresses"}}},
      },
      "/api/v1/captures/{captureId}/words/{address}": {
        "parameters": [CAPTURE-ID-PARAMETER_],
        "get": {"summary": "Decode one tagged runtime word", "responses": {"200": {"description": "Tagged-word evidence"}}},
      },
      "/api/v1/captures/{captureId}/objects/{address}": {
        "parameters": [
          CAPTURE-ID-PARAMETER_,
          {"name": "program", "in": "query", "schema": {"type": "string", "pattern": "^0x[0-9a-fA-F]+\$"}},
        ],
        "get": {"summary": "Decode one object header and structural payload", "responses": {"200": {"description": "Object evidence"}}},
      },
      "/api/v1/captures/{captureId}/objects/{address}/edges": {
        "parameters": [
          CAPTURE-ID-PARAMETER_,
          {"name": "program", "in": "query", "required": true, "schema": {"type": "string", "pattern": "^0x[0-9a-fA-F]+\$"}},
          {"name": "offset", "in": "query", "schema": {"type": "integer", "minimum": 0}},
          {"name": "limit", "in": "query", "schema": {"type": "integer", "minimum": 1, "maximum": 500}},
        ],
        "get": {"summary": "List an object's captured pointer edges", "responses": {"200": {"description": "Object edge page"}}},
      },
      "/api/v1/captures/{captureId}/objects/{address}/inspect": {
        "parameters": [
          CAPTURE-ID-PARAMETER_,
          {"name": "object-heap", "in": "query", "required": true, "schema": {"type": "string", "pattern": "^0x[0-9a-fA-F]+\$"}},
          {"name": "depth", "in": "query", "schema": {"type": "integer", "minimum": 0, "maximum": 8}},
          {"name": "max-objects", "in": "query", "schema": {"type": "integer", "minimum": 1, "maximum": 500}},
          {"name": "max-elements", "in": "query", "schema": {"type": "integer", "minimum": 1, "maximum": 500}},
        ],
        "get": {
          "summary": "Inspect a bounded object graph with inferred program metadata",
          "description": "Returns named fields, inline value summaries, storage classification, and semantic Map, Set, List, and array views. The object heap selects and verifies the exact Program.",
          "responses": {"200": {"description": "Bounded normalized object graph"}},
        },
      },
      "/api/v1/captures/{captureId}/stacks/{address}": {
        "parameters": [
          CAPTURE-ID-PARAMETER_,
          {"name": "program", "in": "query", "required": true, "schema": {"type": "string", "pattern": "^0x[0-9a-fA-F]+\$"}},
        ],
        "get": {"summary": "Decode and symbolize stack frames and live value slots", "responses": {"200": {"description": "Stack-frame evidence"}}},
      },
      "/api/v1/captures/{captureId}/runtime": {
        "parameters": [CAPTURE-ID-PARAMETER_],
        "get": {"summary": "Discover VM, process groups, processes, and heap spaces", "responses": {"200": {"description": "Runtime evidence"}}},
      },
      "/api/v1/captures/{captureId}/process-stacks": {
        "parameters": [CAPTURE-ID-PARAMETER_],
        "get": {
          "summary": "Discover every process stack and decode its frames and live variables",
          "responses": {"200": {"description": "Process-associated stack evidence"}},
        },
      },
      "/api/v1/captures/{captureId}/process-variables": {
        "parameters": [CAPTURE-ID-PARAMETER_],
        "get": {
          "summary": "Discover process globals, stacks, frames, and live variables",
          "responses": {"200": {"description": "Debugger-oriented process variable evidence"}},
        },
      },
      "/api/v1/captures/{captureId}/symbolize": {
        "parameters": [CAPTURE-ID-PARAMETER_],
        "get": {
          "summary": "Symbolize a BCI for a captured or live Toit Program",
          "parameters": [
            {"name": "program", "in": "query", "required": true, "schema": {"type": "string", "pattern": "^0x[0-9a-fA-F]+\$"}},
            {"name": "bci", "in": "query", "required": true, "schema": {"type": "integer", "minimum": 0}},
          ],
          "responses": {"200": {"description": "Method and source evidence"}},
        },
      },
      "/api/v1/captures/{captureId}/memory-accounting": {
        "parameters": [CAPTURE-ID-PARAMETER_],
        "get": {
          "summary": "Reconcile modeled allocations with typed ownership roots",
          "description": "Keeps allocation-site tags separate from current strong owners. With exact firmware descriptions, stopped full-device targets also include declared static/reserved physical regions and report whether releasable regions have returned to the allocator.",
          "responses": {"200": {"description": "Component accounting, per-allocation evidence, and leak-analysis coverage"}},
        },
      },
      "/api/v1/captures/{captureId}/heap-census": {
        "parameters": [CAPTURE-ID-PARAMETER_],
        "get": {
          "summary": "Account objects in one captured heap range",
          "parameters": [
            {"name": "start", "in": "query", "required": true, "schema": {"type": "string", "pattern": "^0x[0-9a-fA-F]+\$"}},
            {"name": "end", "in": "query", "required": true, "schema": {"type": "string", "pattern": "^0x[0-9a-fA-F]+\$"}},
            {"name": "program", "in": "query", "required": true, "schema": {"type": "string", "pattern": "^0x[0-9a-fA-F]+\$"}},
            {"name": "space-kind", "in": "query", "schema": {"type": "string", "enum": ["old-space", "new-space"]}},
            {"name": "offset", "in": "query", "schema": {"type": "integer", "minimum": 0}},
            {"name": "limit", "in": "query", "schema": {"type": "integer", "minimum": 0, "maximum": 500}},
          ],
          "responses": {"200": {"description": "Heap census and object page"}},
        },
      },
      "/api/v1/captures/{captureId}/retainers": {
        "parameters": [CAPTURE-ID-PARAMETER_],
        "get": {
          "summary": "Find direct retainers in one captured heap range",
          "parameters": [
            {"name": "start", "in": "query", "required": true, "schema": {"type": "string", "pattern": "^0x[0-9a-fA-F]+\$"}},
            {"name": "end", "in": "query", "required": true, "schema": {"type": "string", "pattern": "^0x[0-9a-fA-F]+\$"}},
            {"name": "program", "in": "query", "required": true, "schema": {"type": "string", "pattern": "^0x[0-9a-fA-F]+\$"}},
            {"name": "target", "in": "query", "required": true, "schema": {"type": "string", "pattern": "^0x[0-9a-fA-F]+\$"}},
            {"name": "offset", "in": "query", "schema": {"type": "integer", "minimum": 0}},
            {"name": "limit", "in": "query", "schema": {"type": "integer", "minimum": 1, "maximum": 500}},
          ],
          "responses": {"200": {"description": "Direct retainer page"}},
        },
      },
      "/api/v1/captures/{captureId}/retention-path": {
        "parameters": [CAPTURE-ID-PARAMETER_],
        "get": {
          "summary": "Find a bounded path from a captured process root to one object",
          "parameters": [
            {"name": "object-heap", "in": "query", "required": true, "schema": {"type": "string", "pattern": "^0x[0-9a-fA-F]+\$"}},
            {"name": "target", "in": "query", "required": true, "schema": {"type": "string", "pattern": "^0x[0-9a-fA-F]+\$"}},
            {"name": "max-nodes", "in": "query", "schema": {"type": "integer", "minimum": 1, "maximum": 100000}},
            {"name": "max-depth", "in": "query", "schema": {"type": "integer", "minimum": 0, "maximum": 1024}},
          ],
          "responses": {"200": {"description": "Retention path evidence"}},
        },
      },
      "/api/v1/captures/{captureId}/retained-size": {
        "parameters": [CAPTURE-ID-PARAMETER_],
        "get": {
          "summary": "Compute the objects and bytes retained by one object",
          "parameters": [
            {"name": "object-heap", "in": "query", "required": true, "schema": {"type": "string", "pattern": "^0x[0-9a-fA-F]+\$"}},
            {"name": "target", "in": "query", "required": true, "schema": {"type": "string", "pattern": "^0x[0-9a-fA-F]+\$"}},
            {"name": "max-nodes", "in": "query", "schema": {"type": "integer", "minimum": 1, "maximum": 100000}},
            {"name": "offset", "in": "query", "schema": {"type": "integer", "minimum": 0}},
            {"name": "limit", "in": "query", "schema": {"type": "integer", "minimum": 1, "maximum": 500}},
          ],
          "responses": {"200": {"description": "Retained-size evidence"}},
        },
      },
      "/api/v1/captures/{captureId}/transitive-size": {
        "parameters": [CAPTURE-ID-PARAMETER_],
        "get": {
          "summary": "Compute the inclusive object graph reachable from one value",
          "description": "Counts the target and every transitively reachable heap object. Objects shared with other roots remain included; this differs from retained size.",
          "parameters": [
            {"name": "object-heap", "in": "query", "required": true, "schema": {"type": "string", "pattern": "^0x[0-9a-fA-F]+\$"}},
            {"name": "target", "in": "query", "required": true, "schema": {"type": "string", "pattern": "^0x[0-9a-fA-F]+\$"}},
            {"name": "max-nodes", "in": "query", "schema": {"type": "integer", "minimum": 1, "maximum": 100000}},
            {"name": "offset", "in": "query", "schema": {"type": "integer", "minimum": 0}},
            {"name": "limit", "in": "query", "schema": {"type": "integer", "minimum": 1, "maximum": 500}},
          ],
          "responses": {"200": {"description": "Inclusive transitive-size evidence"}},
        },
      },
      "/api/v1/captures/{captureId}/attachments": {
        "parameters": [CAPTURE-ID-PARAMETER_],
        "get": {"summary": "List exact external attachment identities", "responses": {"200": {"description": "Attachment page"}}},
      },
      "/api/v1/captures/{captureId}/attachments/{attachmentId}": {
        "parameters": [
          CAPTURE-ID-PARAMETER_,
          {"name": "attachmentId", "in": "path", "required": true, "schema": {"type": "string"}},
        ],
        "get": {"summary": "Read an attachment identity", "responses": {"200": {"description": "Attachment identity"}}},
      },
      "/api/v1/captures/{captureId}/register-sets": {
        "parameters": [CAPTURE-ID-PARAMETER_],
        "get": {"summary": "List captured per-core register sets", "responses": {"200": {"description": "Register-set page"}}},
      },
      "/api/v1/captures/{captureId}/register-sets/{registerSetId}": {
        "parameters": [
          CAPTURE-ID-PARAMETER_,
          {"name": "registerSetId", "in": "path", "required": true, "schema": {"type": "string"}},
        ],
        "get": {"summary": "Read an encoded register set", "responses": {"200": {"description": "Register set"}}},
      },
    },
  }

CAPTURE-ID-PARAMETER_ ::= {
  "name": "captureId",
  "in": "path",
  "required": true,
  "schema": {"type": "string"},
}
