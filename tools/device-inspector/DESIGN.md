# Device inspector design notes

The primary target is an arbitrary hardware stop. A capture may interrupt a
core in the interpreter, a primitive, the scheduler, or any garbage-collector
phase. A cooperative global safepoint is still useful as a reference capture
and test oracle, but must not become a prerequisite for analysis.

## Architecture boundary

Acquisition and interpretation are separate inputs:

```text
 .toitdump bytes ──> Capture target ───────┐
                                           ├──> Inspector ──> query model
 GDB RSP/JTAG ────> GdbTarget ─────────────┘         ▲
                                                     │
 envelope description + snapshot ──> Toit Interpretation ─┘
```

A `Target` knows only address ranges and how to read them. A mutable stopped
target additionally writes memory and reports stop context. It has no Toit
layout metadata. `Interpretation` owns the exact envelope-derived runtime,
native-ownership, and program descriptions.
The internal `View` composes both for the low-level VM decoder, and `Inspector`
is the public semantic surface. A dump happens to store both bytes and layout
attachments in one artifact, but the API does not make that an architectural
requirement.

The GDB RSP target performs bounded reads on demand; it does not prefetch a
whole device or synthesize a capture. This is suitable for QEMU's stub and for
JTAG servers used with ESP32-C3/C6/S3. Caching, stop generation, and invalidation
belong in that acquisition layer. Object layouts, GC state, block encoding,
program matching, globals, and stack interpretation belong above it.

The debugger-facing unit is a BCI plus a Program identity. `Inspector` resolves
the Program's bytecode identity using the VM layout, selects the checksum-
matched snapshot interpretation, and returns method/source information. Thus a
terminal, editor, or agent can ask `symbolize-bci PROGRAM BCI` without knowing
where `Program::bytecodes` is stored. Register-to-BCI recovery for arbitrary
stops is a separate architecture-specific adapter that will feed the same
operation.

## Capture consistency

Keep these properties separate:

- **transport completeness**: every promised byte arrived and passed its
  checksum;
- **hardware quiescence**: which CPUs and peripherals were stopped, and when;
- **semantic coherence**: whether the runtime had published a normal heap and
  synchronized interpreter registers to memory.

The current UART path freezes the peer CPU and mutates the calling CPU while it
streams memory. It is therefore `asynchronous` and not semantically coherent,
even when the transport is complete. A debugger that halts every CPU before
reading memory has a stronger hardware boundary, but can still stop in the
middle of garbage collection.

## Evidence required for arbitrary-stop decoding

Memory alone is insufficient when a core owns newer state in registers. A
capture intended for full analysis should eventually include:

- the complete general and special register set for every core, including PC
  and SP;
- the CPU-visible memory map and cache/MMU state needed to resolve aliases and
  mapped PSRAM;
- the exact firmware envelope and application snapshots, identified by digest;
- its versioned inspector description, bound to the native ELF/image identity;
- runtime layout/version information;
- peripheral/DMA stop state;
- if practical, an explicit GC phase and its active heap/cursor identifiers.

The explicit GC record is a robustness feature rather than a requirement. For
older captures the decoder can infer candidate phases from each core's PC,
the exact ELF, collector fields, mark bits, forwarding pointers, and space
boundaries.

Instrumented test builds expose named checkpoints at the mutator arm gate and
through scavenging, marking, sweeping, and compaction. QEMU starts paused, the
GDB client writes one requested checkpoint only after firmware initialization,
and the runtime then stops at that exact boundary. Each capture records the
checkpoint ID, context pointer, debugger stop replies, and symbol layout as
evidence. This makes phase-specific decoder fixtures repeatable without
changing the arbitrary-stop contract. Production builds leave the
instrumentation disabled, and mid-collector checkpoints remain explicitly not
semantically coherent.

## Decoder contract

The decoder should preserve facts separately from interpretations. It should
never silently force a mid-operation heap into the normal object model.
Queries should be able to return, for example:

- a word's bytes, address, region, and acquisition flags;
- candidate values and the reason each interpretation applies;
- object state such as normal, marked, forwarded, being-scavenged, or
  structurally invalid;
- confidence and diagnostics for edges in the object graph;
- the core, frame, register, stack slot, or heap structure that retains an
  object.

This also gives agents a useful API: they can ask progressively narrower
questions, inspect the supporting bytes and metadata, and distinguish
“unknown” from “not present.” HTTP/JSON remains the primary boundary so the
browser, terminal clients, editor integrations, and agents all exercise the
same decoder.

Human rendering is additive evidence, not a replacement representation. A
decoded value retains its raw word, tagged interpretation, address, region,
storage class, and confidence while optionally adding a short `display`
string. Context-sensitive interpretations such as stack-relative blocks also
retain the encoded Smi and state exactly why it resolves to a stack slot and
block method.

## Debugger-style clients

A GDB-like terminal or editor interface should be a client of the same query
model, rather than another decoder. The current operations map naturally:

- `info processes` and `info heaps` use runtime discovery;
- `info globals`, `info args`, and `info locals` select records from the
  process-variable response;
- `print` starts from a variable record and follows the object endpoint;
- bounded object inspection infers the Program from the selected object heap,
  exposes named fields, and renders core collections without hiding raw slots;
- `x` uses bounded memory reads, while raw tagged words remain available on
  every variable;
- `bt` uses the frames already returned for each process stack;
- following a block selects its reported stack and target slot.

`GET /api/v1/captures/{id}/process-variables` is the initial debugger-oriented
boundary, and `device-inspector variables` exposes the same JSON without an
HTTP server. A future interactive command loop can therefore concentrate on
selection state, expression syntax, and presentation. It should not learn
heap layouts, block encoding, snapshot matching, or GC rules itself.

## Memory ownership accounting

Memory accounting is an interval graph above the transport and Toit decoders.
An allocation record identifies an address, size, storage class, origin, and
evidence; a typed root assigns a component and retention strength; an edge
records ownership, containment, membership, borrowing, or weakness. Strong
roots and ownership/containment edges propagate component ownership. Multiple
components reaching one allocation make it shared instead of arbitrarily
charging it to the first root.

Allocator tags and ownership roots answer different questions. Tags describe
the context in which an allocation was made (`lwip`, `wifi`, Toit heap,
external object, event source, thread, Bluetooth, unknown, or untagged).
Concrete resource-group and resource types describe who currently owns native
objects and their declared buffers. Both are generic inputs: no subsystem is
special-cased by the accounting algorithm, and every absent tag/root category
is reported as a coverage gap rather than silently assigned to `misc`.

Physical-region declarations are a third, non-overlapping input. The exact
firmware description records component-owned linked sections and SDK-reserved
address intervals. At inspection time the allocator registry decides whether a
releasable interval is still owned by that component or has been returned to
general allocation. Returned intervals are evidence, but are not charged to
the former owner or added on top of allocator capacity. Declaration coverage is
component-scoped; describing Bluetooth must not imply that Wi-Fi or every other
linked archive has been accounted for.

For compact-malloc firmware, the offline allocator decoder walks the ELF-
described `registered_heaps` list, large page runs, small-allocation arenas,
free areas, per-allocation headers, and raw tags. It executes no target code.
`complete` here means that every linked allocator structure in the captured
image passed structural traversal; it does not by itself prove the image was
stopped between allocator transactions. Arbitrary-stop consistency remains a
separate coverage dimension.

Reachability terminology is deliberately conservative. A modeled allocation
without a decoded strong root is `unexplained` while either allocator-block or
root coverage is incomplete. It becomes a `leak-candidate` only after both are
complete, and is never automatically called a confirmed leak. This avoids
turning an unknown driver root, DMA owner, interrupted allocator update, or
uncaptured PSRAM dependency into a false diagnosis.

The HTTP endpoint and CLI return this model directly. Browser, agent, future
GDB-like, and editor clients only choose presentation and filtering; they do
not independently reconstruct ownership.

## Capture scope

A single-container capture uses the same artifact and decoder as a full-device
capture. It is a selective evidence set, not a second format. Acquisition is
necessarily two-pass when the debugger does not already know ownership:

1. Read the small shared bootstrap set needed to locate the VM, scheduler,
   process groups, processes, heaps, and programs.
2. Resolve the selected container and capture its heap chunks, stacks, program
   data, registers that retain its state, and externally owned allocations.

The artifact must record the selected container identity, the bootstrap/shared
regions, omitted containers, and why each unresolved allocation was excluded.
Shared allocations may be included with shared ownership rather than assigned
to one container. An address not included by the selection must decode as “not
captured”; it must not be treated as corrupt memory.

External memory is the difficult part of the ownership closure. The planner
uses evidence from heap-object payload pointers, external-memory accounting,
native resource groups, resource objects, notifiers, and available PSRAM
mappings. ELF-derived vtables identify dynamic native types, while a declared
layout registry determines which full structures are safe to capture. Unknown
driver tails, allocator blocks, and DMA descriptors stay explicit
unknown/shared dependencies until their layouts or runtime ownership metadata
are available; reachability alone does not prove container ownership.

## Temporary tooling boundaries

The firmware build currently invokes stock GDB to evaluate DWARF types,
symbols, and native expressions from the exact ELF. It combines those resolved
facts with the SDK's declarative ownership recipes and stores the result as a
versioned envelope entry. This is an isolated, replaceable build boundary: the
inspector and capture tools consume the envelope description and never invoke
GDB. A native Toit ELF/DWARF reader can replace the generator without changing
envelopes, captures, acquisition, the HTTP API, or decoder queries.

Named runtime checkpoints and their debug primitive are opt-in test
instrumentation. They validate phase-specific decoders but are not part of the
production capture contract. The Toit GDB Remote Serial Protocol client is a
separate transport component and may remain useful for QEMU and physical
JTAG/OpenOCD capture even after offline GDB is removed.

## Suggested decoding order

1. Validate the normalized artifact and expose raw regions and registers.
2. Resolve firmware symbols and runtime globals from the exact ELF.
3. Decode scheduler, process, and container structures from a reference
   safepoint capture.
4. Decode normal heap objects, stacks, bytecode frames, and retention paths.
5. Add GC-phase-specific heap views and validate them with deterministic QEMU
   stops inside each collector phase.
6. Add arbitrary-PC register unwinding and reconcile register-owned state with
   memory-owned state.

The normal-heap decoder now exposes bounded outgoing object edges, a direct
retainer scan over one captured heap range, and a breadth-first retention path
over both spaces of one process. Instance and task edges use the flattened
inherited field order from the checksum-matched snapshot; array and published-
stack edges preserve their element or frame-slot location. The memory-owned
root decoder covers `ObjectHeap::task_`, per-process global-variable slots,
external roots, object notifiers, and all three finalizer queues. It separates
categories decoded completely from categories whose native nodes were not
captured. Finalizer edges preserve GC strength: registered keys are weak,
whereas runnable keys and callable lambdas are strong. Interpreter register
roots are classified from the captured task's stack state. At published-stack
checkpoints the heap owns the live stack top and the register category is not
applicable; inside the interpreter, register roots remain explicitly required
and the root set is incomplete. The retained-size query performs paired
strong-root traversals (with and without the target), accounts deduplicated
external payloads, and marks its result authoritative only when the roots and
both traversals are complete. A dominator tree remains the more efficient
future representation for answering this query repeatedly.

Interpreter frame markers plus snapshot method arity distinguish argument
slots from the caller's remaining live stack values. Snapshot source maps also
resolve frame BCIs to methods, source positions, and instructions. A separate,
optional frame-debug source-map segment now records ordered parameters and
source-local stack-slot lifetimes. This lets matching version-2 program layouts
separate named parameters, active locals, and operand-stack temporaries while
older snapshots remain readable. The metadata describes physical lexical
lifetimes—the period for which a local occupies a stack slot—which is the
relevant lifetime for memory retention.
