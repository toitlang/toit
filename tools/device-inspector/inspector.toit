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

import .runtime as vm
import .memory-accounting as accounting
import .object-inspection as object-inspection
import .target as target
import .toit-model as toit-model

/** Provides semantic Toit queries over a frozen or stopped live target. */
class Inspector:
  target_/target.Target
  interpretation_/toit-model.Interpretation
  view_/toit-model.View

  constructor .target_ .interpretation_:
    view_ = toit-model.View target_ interpretation_

  /** Decodes one tagged Toit word. */
  word address/int -> Map:
    return vm.decode-word view_ address

  /** Decodes one object, optionally using its program for exact class data. */
  object address/int program/int?=null -> Map:
    if not program: return vm.decode-object view_ address
    return vm.decode-object-with-program
        view_
        address
        program
        runtime-layout_

  /** Discovers the VM, process groups, processes, and heaps. */
  runtime -> Map:
    return vm.decode-runtime view_ runtime-layout_

  /** Discovers globals, stacks, frames, arguments, locals, and operands. */
  process-variables -> Map:
    return vm.decode-process-stacks view_ runtime-layout_

  /** Reconciles modeled memory with typed component ownership roots. */
  memory-accounting -> Map:
    scope := interpretation_.metadata.get "capture-scope"
    return accounting.build
        target_
        runtime
        scope
        runtime-layout_
        interpretation_.inspector-description

  /** Decodes one published heap stack. */
  stack address/int program/int -> Map:
    return vm.decode-stack view_ address program runtime-layout_

  /** Searches target memory without requiring transport-specific access. */
  search pattern/ByteArray limit/int -> Map:
    return vm.search-bytes view_ pattern limit

  /** Decodes the outgoing object references at $address. */
  object-edges address/int program/int offset/int limit/int -> Map:
    return vm.object-edges view_ address program runtime-layout_ offset limit

  /** Inspects a bounded object graph using its process heap's exact program. */
  inspect-object
      object-heap/int object/int max-depth/int max-objects/int max-elements/int
      -> Map:
    return object-inspection.inspect-process-object
        view_
        object-heap
        object
        runtime-layout_
        max-depth
        max-objects
        max-elements

  /** Finds heap objects that directly retain $object. */
  direct-retainers
      start/int end/int program/int object/int offset/int limit/int
      -> Map:
    layout := runtime-layout_
    return vm.direct-retainers view_ start end program object layout offset limit

  /** Finds one root-to-object retention path in a process heap. */
  retention-path
      object-heap/int object/int max-nodes/int max-depth/int
      -> Map:
    layout := runtime-layout_
    return vm.process-retention-path view_ object-heap object layout max-nodes max-depth

  /** Computes retained sizes for objects reachable from a process heap. */
  retained-size
      object-heap/int object/int max-nodes/int offset/int limit/int
      -> Map:
    layout := runtime-layout_
    return vm.process-retained-size view_ object-heap object layout max-nodes offset limit

  /** Computes the inclusive object graph reachable from one value. */
  transitive-size
      object-heap/int object/int max-nodes/int offset/int limit/int
      -> Map:
    layout := runtime-layout_
    return vm.process-transitive-size view_ object-heap object layout max-nodes offset limit

  /** Counts and groups objects in one heap address interval. */
  heap-census
      start/int end/int program/int offset/int limit/int
      --space-kind/string?=null
      -> Map:
    return vm.heap-range-census
        view_
        start
        end
        program
        runtime-layout_
        offset
        limit
        --space-kind=space-kind

  /** Exposes the composed view to low-level analysis modules. */
  view -> toit-model.View:
    return view_

  /** Symbolizes a BCI for a live or captured Program. */
  symbolize-bci program/int bci/int -> Map:
    return vm.symbolize-program-bci view_ program runtime-layout_ bci

  /** Symbolizes a BCI when the caller has already selected a program layout. */
  symbolize-layout-bci program-layout/Map bci/int -> Map:
    return toit-model.symbolize-bci program-layout bci

  runtime-layout_ -> Map:
    layout := interpretation_.runtime-layout
    if not layout: throw "RUNTIME_LAYOUT_NOT_AVAILABLE"
    return layout
