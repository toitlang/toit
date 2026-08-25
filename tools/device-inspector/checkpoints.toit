// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.json
import host.file
import io

import ..gdb.src.gdb as gdb
import .format as format

LAYOUT-FORMAT ::= "toit-inspector-checkpoints"
LAYOUT-VERSION ::= 1

ARM-SYMBOL ::= "toit_vm_state_checkpoint_arm_gate"
HIT-SYMBOL ::= "toit_vm_state_checkpoint_hit"
REQUESTED-SYMBOL ::= "toit_vm_state_checkpoint_requested"
CURRENT-SYMBOL ::= "toit_vm_state_checkpoint_current"
CONTEXT-SYMBOL ::= "toit_vm_state_checkpoint_context"

CHECKPOINT-SPECS ::= [
  {"name": "mutator-armed", "enum": "toit::VM_STATE_MUTATOR_ARMED"},
  {"name": "scavenge-started", "enum": "toit::VM_STATE_SCAVENGE_STARTED"},
  {"name": "scavenge-after-forwarding", "enum": "toit::VM_STATE_SCAVENGE_AFTER_FORWARDING"},
  {"name": "scavenge-after-roots", "enum": "toit::VM_STATE_SCAVENGE_AFTER_ROOTS"},
  {"name": "scavenge-complete", "enum": "toit::VM_STATE_SCAVENGE_COMPLETE"},
  {"name": "mark-after-roots", "enum": "toit::VM_STATE_MARK_AFTER_ROOTS"},
  {"name": "mark-complete", "enum": "toit::VM_STATE_MARK_COMPLETE"},
  {"name": "sweep-started", "enum": "toit::VM_STATE_SWEEP_STARTED"},
  {"name": "compaction-started", "enum": "toit::VM_STATE_COMPACTION_STARTED"},
  {"name": "gc-complete", "enum": "toit::VM_STATE_GC_COMPLETE"},
]

checkpoint-for-name checkpoint-layouts/List name/string -> Map:
  checkpoint-layouts.do: | checkpoint/Map |
    if checkpoint["name"] == name: return checkpoint
  throw "UNKNOWN_INSPECTOR_CHECKPOINT"

load-layout path/string -> Map:
  layout/Map := json.decode (file.read-contents path)
  if (layout.get "format") != LAYOUT-FORMAT or
      (layout.get "format-version") != LAYOUT-VERSION or
      (layout.get "pointer-size") != 4 or
      (layout.get "byte-order") != "little":
    throw "INVALID_INSPECTOR_CHECKPOINT_LAYOUT"
  checkpoint-layouts := layout.get "checkpoints"
  if not checkpoint-layouts is List or checkpoint-layouts.size != CHECKPOINT-SPECS.size:
    throw "INVALID_INSPECTOR_CHECKPOINT_LAYOUT"
  CHECKPOINT-SPECS.do: | spec/Map |
    checkpoint := checkpoint-for-name checkpoint-layouts spec["name"]
    checkpoint-id := checkpoint.get "id"
    if not checkpoint-id is int or checkpoint-id <= 0:
      throw "INVALID_INSPECTOR_CHECKPOINT_LAYOUT"
  return layout

run-to-checkpoint client/gdb.Client layout/Map name/string -> Map:
  checkpoint := checkpoint-for-name layout["checkpoints"] name
  symbols/Map := layout["symbols"]
  arm-address := symbol-address symbols ARM-SYMBOL
  hit-address := symbol-address symbols HIT-SYMBOL
  requested-address := symbol-address symbols REQUESTED-SYMBOL
  current-address := symbol-address symbols CURRENT-SYMBOL
  context-address := symbol-address symbols CONTEXT-SYMBOL

  client.insert-software-breakpoint arm-address
  client.insert-software-breakpoint hit-address
  arm-stop := client.continue-execution
  requested := ByteArray 4
  io.LITTLE-ENDIAN.put-uint32 requested 0 checkpoint["id"]
  client.write-memory requested-address requested
  client.remove-software-breakpoint arm-address
  hit-stop := client.continue-execution

  current-bytes := client.read-memory current-address 4
  actual-id := io.LITTLE-ENDIAN.uint32 current-bytes 0
  if actual-id != checkpoint["id"]: throw "INSPECTOR_CHECKPOINT_MISMATCH"
  context-bytes := client.read-memory context-address 4
  context := io.LITTLE-ENDIAN.uint32 context-bytes 0
  return {
    "name": name,
    "id": checkpoint["id"],
    "context": format.hex-address context,
    "arm-stop": stop-detail arm-stop,
    "hit-stop": stop-detail hit-stop,
  }

symbol-address symbols/Map name/string -> int:
  value := symbols.get name
  if not value is string: throw "INSPECTOR_CHECKPOINT_SYMBOL_MISSING"
  return format.parse-address value

stop-detail stop/gdb.StopReply -> Map:
  return {
    "payload": stop.payload,
    "signal": stop.signal,
    "thread-id": stop.thread-id,
  }
