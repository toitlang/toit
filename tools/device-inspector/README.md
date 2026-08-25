# Toit device inspector

This is the analysis-server foundation for full-device captures. Its primary
contract is the versioned HTTP/JSON API. The small browser is an API client;
future agent, terminal, VS Code, and MCP clients should use the same boundary.
See [DESIGN.md](DESIGN.md) for the asynchronous/mid-GC consistency model and
decoder contract.

## Reusable inspector core

The semantic decoder is independent of capture transport:

- `target.toit` is only an address space: identity, mapped regions, bounded
  reads, and (for a stopped debugger target) writes and stop context;
- `toit-model.toit` contains firmware/snapshot interpretation metadata and
  BCI-to-method/source symbolization;
- `inspector.toit` composes those two inputs into debugger-level queries;
- `format.toit` is one address-space implementation backed by a frozen
  `.toitdump` artifact;
- `gdb-target.toit` is another implementation whose reads and writes are
  fetched incrementally through GDB Remote Serial Protocol.

Consequently, a live debugger does not create a fake dump and the GDB/JTAG
transport does not need to understand Toit objects. It stops the target and
provides memory; the exact firmware and snapshot artifacts provide the
independent `Interpretation`; `Inspector` provides words, objects, variables,
stacks, retention queries, and `symbolize-bci PROGRAM BCI`. The latter reads
the small `Program` bytecode identity needed to select the matching snapshot
layout, then returns the method and source location. Clients do not need the
native `Program` field offsets.

This makes a hardware JTAG server for ESP32-C3/C6/S3 a natural live backend:
OpenOCD or another server can expose GDB RSP, while the same inspector model
continues to serve the current browser, agents, a future GDB-like terminal,
or an editor integration. QEMU's GDB stub exercises the same boundary in
tests. Runtime instrumentation remains useful for repeatable GC checkpoint
oracles and UART-only devices, but is not required by the live-query API.

## Import out-of-band regions

Create a manifest next to the files produced by QEMU, GDB, or JTAG:

```json
{
  "target": {
    "chip": "esp32",
    "architecture": "xtensa",
    "word-size": 4,
    "endianness": "little"
  },
  "completeness": {
    "state": "partial",
    "missing-regions": ["psram", "registers"],
    "stopped-cpus": 2
  },
  "provenance": {
    "acquisition": "debugger",
    "capture-mode": "asynchronous",
    "semantic-coherence": false
  },
  "attachments": [
    {"id": "firmware-elf", "kind": "firmware-elf", "file": "firmware.elf"},
    {"id": "envelope", "kind": "firmware-envelope", "file": "firmware.envelope"},
    {"id": "app", "kind": "toit-snapshot", "file": "app.snapshot"}
  ],
  "runtime-layout": {
    "file": "runtime-layout.json",
    "elf-attachment-id": "firmware-elf"
  },
  "program-layouts": [
    {"file": "program-layout.json", "snapshot-attachment-id": "app"}
  ],
  "regions": [
    {
      "id": "dram",
      "name": "Data RAM",
      "address": "0x3ffae000",
      "size": 335872,
      "kind": "ram",
      "permissions": "rw",
      "file": "dram.bin"
    }
  ]
}
```

The importer uses the actual file size and records its checksum. It rejects
overlapping virtual regions. A capture defaults to `partial` unless the
manifest explicitly says `complete`. Attachment files remain external, but
their kind, name, byte size, SHA-256 identity, and optional metadata are bound
into the artifact's content ID. Optional declared sizes and checksums are
verified during import.

New ESP32 firmware builds generate a compact, versioned inspector description
from the exact DWARF-bearing firmware ELF and store it as `$inspector.json` in
the envelope. It contains the resolved runtime layout, the firmware ELF size
and SHA-256, and a separately versioned native-ownership description. The
firmware tool rejects a description whose identity does not match the ELF.
Container installation and other envelope mutations preserve the entry.

When a capture manifest contains one `firmware-envelope` attachment, the
importer verifies the description against the ELF stored inside that envelope,
copies the description into the `.toitdump`, and uses its runtime layout
automatically. Selective QEMU capture uses the same entry while planning which
container-owned ranges to read. Thus serving or querying the resulting dump
does not execute GDB and does not need the external envelope anymore.

The current envelope-build generator temporarily invokes the architecture's
GNU GDB as a DWARF query engine:

```sh
build/host/sdk/bin/toit run --project-root tools \
  tools/device-inspector/extract-description.toit -- \
  xtensa-esp32s3-elf-gdb firmware.elf inspector.json
```

Set `TOIT_GDB` when the debugger is not on `PATH`. This is a firmware-build
dependency only. The server, artifact reader, decoder, HTTP clients, and agents
never invoke it. The QEMU/JTAG acquisition path separately uses the reusable
Toit GDB Remote Serial Protocol package in `tools/gdb`; that protocol client is
not an ELF/DWARF reader. A future Toit ELF/DWARF package can replace the current
description generator without changing the envelope or inspector interfaces.

For old envelopes, the legacy `runtime-layout` manifest input remains
supported. Generate that sidecar with `extract-runtime-layout.toit` and attach
the matching ELF as before. When both the envelope description and the legacy
sidecar are supplied, their structural layouts must match.

Generate the bytecode/method/source index from each exact Toit snapshot. The
importer binds it to the snapshot attachment's SHA-256, and the decoder also
matches its bytecode checksum to the captured `Program`:

```sh
build/host/sdk/bin/toit run --project-root tools \
  tools/device-inspector/extract-program-layout.toit -- \
  capture/app.snapshot capture/program-layout.json
```

```sh
build/host/sdk/bin/toit run --project-root tools \
  tools/device-inspector/device-inspector.toit -- \
  import capture/manifest.json capture/device.toitdump
```

## Import a UART `TDM1` stream

Capture the console UART as raw binary, including any console bytes that occur
before the dump, then normalize it with:

```sh
build/host/sdk/bin/toit run --project-root tools \
  tools/device-inspector/device-inspector.toit -- \
  import-tdm1 uart-capture.bin capture/device.toitdump
```

Pass an optional semantic metadata file as the final argument to bind the raw
stream to the exact envelope, installed snapshots, and their program layouts:

```sh
build/host/sdk/bin/toit run --project-root tools \
  tools/device-inspector/device-inspector.toit -- \
  import-tdm1 uart-capture.bin capture/device.toitdump \
  capture/semantic-metadata.json
```

The metadata file accepts the same `attachments`, `program-layouts`, and
`capture-scope` entries as a normal import manifest. It can additionally name
the exact application image as immutable target memory:

```json
{
  "attachments": [
    {"id":"envelope","kind":"firmware-envelope","file":"firmware.envelope"},
    {"id":"system","kind":"toit-snapshot","file":"system.snapshot",
     "metadata":{"container":"system"}},
    {"id":"app-image","kind":"esp32-app-image","file":"firmware.bin"}
  ],
  "program-layouts": [
    {"file":"system-program-layout.json","snapshot-attachment-id":"system"}
  ],
  "memory-images": [
    {"attachment-id":"app-image","format":"esp32-app-image"}
  ],
  "capture-scope": {"kind":"full-device"}
}
```

Generate `firmware.bin` from the final envelope after installing all
containers. The small Toit image reader validates the ESP application image
and adds its DROM segment as `flash-mapped-data`. This supplies relocated
program objects, class bits, constants, and other immutable flash data without
retransmitting flash on every UART capture. The image itself is checksum-bound
as an attachment; live captured RAM remains a separate source.

The importer follows `tools/device-memory-dump/README.md` version 1 exactly.
It scans past leading console noise and false `TDM1` candidates, validates the
IEEE CRC-32 and bounded length of every accepted frame, and checks global
sequences, info/end payloads, `FIRST`/`LAST`, chunk addresses, region identity,
and end-frame totals. CRC-invalid bytes are never included. If a lost frame
crosses an active region, that entire region is discarded; later independent
valid regions can still be retained.

An absent end frame, CRC loss, sequence gap, structural error, truncated PSRAM,
or mismatched totals produces a `partial` artifact with stable reason codes.
Raw capture flags, raw per-region flags, decoded info/end frames, discarded
noise counts, and transport diagnostics are preserved in metadata. The current
capture mode is labeled `asynchronous` with `semantic-coherence: false`: this
describes what was captured and leaves room for later GC-phase evidence,
rather than treating asynchronous inspection as a format error. Version-1 CPU
evidence frames are normalized into the same per-core register-set model used
by QEMU/JTAG captures.

## Serve the API and browser

The server binds only to `127.0.0.1`. Port `0` selects a free port and the
first output line is deterministic JSON containing the URL and capture ID.

```sh
build/host/sdk/bin/toit run --project-root tools \
  tools/device-inspector/device-inspector.toit -- \
  serve capture/device.toitdump 0
```

The browser's **Processes and stacks** table follows each decoded process to
its globals, task, and heap stack. Expanding a process shows every captured
global and whether it currently keeps mutable memory alive, then presents
decoded frames with named parameters, active locals, operand-stack values,
methods, instructions, and source positions. A human-readable toggle switches
between summarized values and exact raw tagged words. References report their
captured storage region, so flash, internal RAM, external RAM, and uncaptured
targets remain distinct. Encoded blocks resolve to the exact slot in their
owning stack and the block method/source stored there. Object references link
to the object decoder. Parameters are displayed as members of the callee frame,
even though their physical words live in its caller's stack segment; an
optional physical-placement toggle exposes that implementation detail. At an
exact current bytecode, the decoder also labels unambiguous operand roles such
as binary left/right values, branch conditions, and parameters for a pending
call. Static calls use the snapshot dispatch table to recover the target's
parameter names; block calls use the decoded block-to-stack/method link for
the same purpose. Stack-relative block anchors and their four-slot unwind-link
records are shown separately as **Stack blocks** and **VM control state**, not
as unnamed operands. The link is identified structurally from the resolved
block-reference-to-anchor distance, so it remains valid while an exception or
non-local return is updating the record. Caller return addresses are not treated as executing
instructions, so ambiguous suspended operands remain unnamed. Interpreter-owned stacks explain why their frames
cannot yet be recovered from heap memory alone.

The **System memory accounting** view reconciles modeled allocation intervals
with typed ownership roots. It groups exclusive and shared bytes by component,
keeps internal RAM, external RAM, and flash separate, and lists the complete
firmware allocator-tag vocabulary even when allocator blocks have not yet been
decoded. Envelope-declared physical regions keep dynamic/runtime bytes,
statically linked `.data`/`.bss`, and SDK-reserved memory separate. A releasable
region is charged to its declared component only while it remains outside the
registered allocator heaps; after an irreversible SDK release call adds it to
the allocator, the region is shown as `released-to-allocator` and is not counted
twice. Coverage names the components with physical-region declarations and
remains partial until every firmware component participates. Coverage is also
part of allocation reachability: `unexplained` means that no decoded
root reaches a modeled allocation, while `leak-candidate` is only used when
both allocation enumeration and the root set are complete. A zero-byte row is
therefore never inferred from a missing decoder. `confirmed-leak-bytes` remains
unknown because reachability alone does not prove intent.

For stopped full-device targets with an exact runtime layout, accounting also
walks every process's native resource groups and external byte-array/string
payload references. It uses the same bounded ownership traversal as selective
capture planning, but only as analysis evidence: a traversal failure leaves the
corresponding root category partial. The browser's **Allocation ownership
evidence** table keeps allocator tags separate from current strong owners and
shows semantic ranges and source-object roots for each modeled allocation.
The exact ELF layout also identifies the `GcMetadata` singleton and its full
extent. New firmware assigns that allocation its own `gc-metadata` allocator
tag; older captures can still recover its `toit-gc` ownership from the static
singleton when their runtime layout contains the required fields and symbol.
The same layout follows `ObjectMemory::spare_chunk_`, so the reserved GC
evacuation page is reported as `toit-gc` instead of appearing as an unused
process heap page. Registered allocator regions are reconciled with allocator
blocks that back them; for example, a 32 KiB IDF heap carved from another heap
is owned by `esp-idf-allocator`, even if its historical allocation tag was
untagged. Finally, the scheduler's thread list is followed through Toit's
`ThreadData` and the FreeRTOS TCB. Scheduler thread objects, task metadata, and
their individual stacks are consequently assigned to
`toit-scheduler-thread:<index>`. The decoder also walks the FreeRTOS current,
ready, delayed, pending, suspended, and terminating task lists. Every remaining
task's TCB and stack is assigned to `freertos-task:<name>@<tcb-address>`.
Root coverage reports task-list and non-task subsystem discovery separately,
so an older runtime layout cannot silently make missing static roots look like
unused memory.
The browser reports allocator-backed reserve pools separately from live bytes
inside those pools. The ESP32-S3 PSRAM configuration's 32 KiB internal/DMA
reserve therefore remains visible as consumed physical capacity without being
presented as 32 KiB of live payload. Event-source ownership follows the VM's
manager list through concrete ELF vtables, declared mutex, condition-variable,
queue, and native-thread fields. The default ESP-IDF event loop, newlib's
global/per-task stdio glue, file buffers and locks, and GPIO's static pin/ISR
tables are also decoded from their matching private ELF layouts. Further
firmware-static roots cover Toit's process/group control allocations and global
variable tables, VM/OS mutexes, the entropy SHA state, ESP-IDF crypto and flash
locks, the lwIP TCP/IP mailbox, GDMA, VFS locks, resource pools, logging tags,
and pthread keys. These are assigned to named components from declared fields;
the decoder does not infer ownership merely from allocation size or tag.

The envelope description declares which bounded native ownership decoders are
applicable to the firmware. It also carries the event-source owned-field table
and the static mutex, direct-root, resource-pool, and lock recipes consumed by
those decoders. It carries exact ELF-symbol bounds for releasable Bluetooth
host/controller data and BSS on supported ESP32 variants, plus the original
ESP32 controller/ROM reservation table when that table is present in the
firmware. Newer ROM-layout reservations still remain an explicit coverage gap
until the matching ROM description is included during envelope construction.
Missing or unsupported decoders remain `not-enumerated`; they
never silently turn absent ownership knowledge into a leak claim. Legacy
captures use the SDK's version-1 compatibility profile and identify that source
in the accounting result. More complex list and subsystem traversal operations
remain stable decoder primitives, while firmware-specific roots and fields are
data in the envelope.

The **Toit heap breakdown** table lists every decoded heap space for the
selected process group. Expanding a space shows its source-class breakdown,
ordered by object bytes. The object drill-down selects one captured heap chunk
and fetches at most 50 object starts per page. Object addresses link to the
corresponding JSON object decoder, including the process's program pointer for
exact class decoding. This view does not fetch uncaptured memory or load an
entire heap into the browser. Each object also has a retained-size action; the
compact result distinguishes object bytes from external payload bytes and
links to the complete JSON evidence. Globals and stack variables that refer to
objects have a separate transitive-memory action. It counts the selected object
and its complete reachable closure, including descendants shared with other
roots; retained size instead measures what only that object keeps alive.

The useful starting points are:

- `GET /api/v1` for capabilities, limits, and links;
- `GET /api/v1/openapi.json` for machine-readable discovery;
- `GET /api/v1/captures` and `GET /api/v1/captures/{id}`;
- `GET /api/v1/captures/{id}/regions?offset=0&limit=100`;
- `GET /api/v1/captures/{id}/memory?address=0x3ffae000&length=256`;
- `GET /api/v1/captures/{id}/attachments` for exact ELF/envelope/snapshot identities;
- `GET /api/v1/captures/{id}/register-sets` and `/register-sets/{registerSetId}`;
- `GET /api/v1/captures/{id}/words/{address}` for tagged-word evidence;
- `GET /api/v1/captures/{id}/objects/{address}` for structural object decoding;
- `GET /api/v1/captures/{id}/stacks/{address}?program=0x...` for frames, named variables, and operand-stack values;
- `GET /api/v1/captures/{id}/process-stacks` to discover every process, task, and stack and return decoded frames and variables without manually joining addresses;
- `GET /api/v1/captures/{id}/process-variables` for the same debugger-oriented model including globals, storage classification, human summaries, and block-to-stack links;
- `GET /api/v1/captures/{id}/symbolize?program=0x...&bci=...` to map a Program-relative BCI to its checksum-matched method and source location;
- `GET /api/v1/captures/{id}/memory-accounting` for component/storage totals, typed roots and edges, per-allocation state, allocator-tag coverage, and leak-analysis coverage;
- `GET /api/v1/captures/{id}/heap-census?start=0x...&end=0x...&program=0x...` for a paged object census and byte accounting;
- `GET /api/v1/captures/{id}/objects/{address}/edges?program=0x...` for named outgoing object references;
- `GET /api/v1/captures/{id}/retainers?start=0x...&end=0x...&program=0x...&target=0x...` for direct inbound references within a heap range;
- `GET /api/v1/captures/{id}/retention-path?object-heap=0x...&target=0x...` for a bounded path from a captured process root;
- `GET /api/v1/captures/{id}/retained-size?object-heap=0x...&target=0x...` for bounded retained-object and byte accounting;
- `GET /api/v1/captures/{id}/transitive-size?object-heap=0x...&target=0x...` for the inclusive object and external-payload closure of one variable value;
- `GET /api/v1/captures/{id}/objects/{address}/inspect?object-heap=0x...&depth=2` for a bounded named object graph with semantic collection contents;
- `GET /api/v1/captures/{id}/memory/search?hex=...` for bounded byte search;
- `GET /api/v1/captures/{id}/runtime` for VM, process, and heap-space discovery.

Memory data is base64 encoded. Reads must fit wholly inside one captured region
and are capped at 64 KiB. Errors have the stable shape
`{"error":{"code":"...","message":"..."}}`. Addresses in requests and
responses are hexadecimal strings so JavaScript clients never lose precision.
Passing `?program=0x...` to an object request lets the decoder use that
program's captured class-bits table for exact instance/task size and tagged
field evidence.
The thin `device-inspector summary CAPTURE.toitdump` and
`device-inspector runtime CAPTURE.toitdump` commands emit the same capture
metadata and runtime model as JSON for shell and agent workflows;
interpretation remains in the shared model used by the HTTP server.
`device-inspector stack CAPTURE.toitdump ADDRESS PROGRAM` exposes the same
stack-frame query without starting HTTP.
`device-inspector symbolize CAPTURE.toitdump PROGRAM BCI` exposes the
debugger-facing BCI query without requiring a client to know VM field offsets.
`device-inspector process-stacks CAPTURE.toitdump` discovers and decodes all
process-associated stacks in one JSON response for shell and agent workflows.
`device-inspector variables CAPTURE.toitdump` exposes the debugger-oriented
alias, including globals and additive human-readable value summaries. Raw
words, addresses, evidence, and diagnostics are always retained.
`device-inspector memory-accounting CAPTURE.toitdump` emits the same component,
storage, ownership, and coverage evidence used by the browser. This is the
preferred agent/CLI entry point for “where does memory go?” questions.
`device-inspector allocator CAPTURE.toitdump RUNTIME_LAYOUT.json` is the
lower-level allocator evidence query. It walks ESP-IDF compact-malloc heap
descriptors, page runs, small-allocation arenas, free areas, and stored tags
directly in stopped memory. It is useful while upgrading an older artifact:
generate a fresh layout from that capture's exact ELF, then inspect allocator
coverage without recapturing or executing code on the device.
`device-inspector heap CAPTURE.toitdump START END PROGRAM [OFFSET LIMIT]`
does the same for a captured heap chunk.
`device-inspector edges CAPTURE.toitdump ADDRESS PROGRAM [OFFSET LIMIT]`
lists the object's captured outgoing references. Instance and task edges use
source field names from the checksum-matched snapshot; stack edges identify
their frame, value role, and stack index.
`device-inspector inspect CAPTURE.toitdump OBJECT_HEAP OBJECT [DEPTH MAX_OBJECTS MAX_ELEMENTS]`
infers and verifies the exact Program from the selected process heap. It emits
a normalized, cycle-safe object graph whose values preserve raw words while
adding class names, field names, display summaries, and RAM/PSRAM/flash
classification. `Map`, `Set`, `List`, and array nodes additionally report
logical length, backing/index capacity, observed tombstones, bounded entries,
and explicit truncation. This is the preferred agent-facing object drill-down;
the explicit-Program `edges` command remains a lower-level evidence query and
rejects a Program whose snapshot layout cannot be matched.
`device-inspector retainers CAPTURE.toitdump START END PROGRAM TARGET [OFFSET LIMIT]`
scans one stable captured heap range for objects that directly reference the
target. It is intentionally a lower-level evidence primitive used by the
rooted graph queries.
`device-inspector path CAPTURE.toitdump OBJECT_HEAP TARGET [MAX_NODES MAX_DEPTH]`
searches both old- and new-space chunks of the selected process. It currently
decodes the authoritative task root, per-process global-variable roots,
external roots, object-notifier roots, and all three finalizer queues. Global
labels come from the checksum-matched snapshot source map, while polymorphic
finalizer nodes use the exact ELF-derived vtable layout. The response separates
decoded, incomplete, and omitted root categories and also records graph limits
and diagnostics. Registered finalizer keys are reported as weak roots and are
not traversed as liveness roots; runnable keys and callable lambdas are strong.
Active-interpreter register roots are classified explicitly. A not-found
result only applies to the decoded root graph while `root-set.complete` is
false. At a published-stack checkpoint, those registers are
classified as not applicable because the interpreter has stored its live stack
top in the captured task object; captures stopped inside the interpreter still
report register roots as required.
`device-inspector retained CAPTURE.toitdump OBJECT_HEAP TARGET [MAX_NODES OFFSET LIMIT]`
computes the objects that become unreachable when traversal through the target
is blocked. It reports object bytes, deduplicated external-payload bytes, a
class breakdown, and a paged retained-object list. The result is marked
`authoritative` only when both the process root set and both graph traversals
are complete.

The browser labels process heaps with the container name carried by the exact
snapshot attachment. Each live object has a **Find root path** action that
shows one decoded strong-root path through named globals, parameters, locals,
fields, and array elements. This is reachability evidence rather than a claim
that the displayed root is the object's only owner; an object may have more
than one path. The accounting API uses the same identity in component names,
for example `toit-container:inspector/process:2/1`.

Published stacks are divided at the runtime's exact frame-marker and bytecode
pointer pairs. Every frame reports its absolute BCI and every value slot keeps
its stack index, address, raw word, tagged-value interpretation, and capture
evidence. With a matching version-2 program layout, each frame also reports its
method, source position, instruction, arity, maximum stack height, named
parameters, and active source locals. The compiler's optional frame-debug
snapshot segment records parameter kinds plus each local's declaration,
stack-height slot, and exact BCI lifetime. Slots not occupied by an active
local are identified as operand-stack temporaries. Version-1 layouts remain
supported and conservatively report those values as `local-or-operand`; API
responses and the browser identify that older metadata explicitly. Stack-
relative block Smis are recognized only when `BLOCK_SALT` resolves to a live
slot containing an exact block-method header BCI from the matching snapshot.
The block record names that method and reports the owning stack, target slot,
frame, and source position. If a
hardware stop finds
`Stack::top_ == -1`, the response reports
`state: interpreter-owned`:
the active interpreter has the current stack pointer in native state, so the
heap object alone is insufficient. Named `gc-complete` captures provide a
published-stack oracle; arbitrary-stop recovery must additionally unwind the
active interpreter/register state.

Version 2 alone does not imply that frame-debug records are present. Captures
made from snapshots without the optional segment report
`FRAME_DEBUG_METADATA_NOT_AVAILABLE`; the browser no longer suggests that
local names should be available in that case.

Runtime discovery walks captured heap chunks to their zero sentinel and adds a
compact census to every old/new space. It accounts object bytes, free-list
bytes, sentinel and unused chunk bytes, and separately owned external payload
bytes. Counts are grouped by runtime type and by source class name from the
checksum-matched snapshot. The explicit heap-census query returns a bounded
page of object starts. Forwarded objects use the captured destination only for
size/type evidence; malformed or unavailable transitional state stops that
chunk with a diagnostic instead of guessing the following boundary.

Every target also exposes stop evidence independently of its byte transport.
A frozen capture normalizes its provenance into an observation; a live GDB/JTAG
target supplies its current stop context. The Toit model classifies that
observation as mutator, scavenge, marking, sweeping, compacting, or unknown.
Only `mutator-armed` and `gc-complete` checkpoints permit the ordinary stable
heap model. Mid-collection censuses remain structurally useful but are marked
non-authoritative and carry phase diagnostics. Scavenging identifies forwarded
live and unforwarded objects in from-space. Marking, sweeping, and compaction
read the VM's exact `GcMetadata` bitmap to distinguish reached/live and
unreached/dead objects. The HTTP heap-census query accepts
`space-kind=old-space` or `space-kind=new-space`; the browser supplies it,
shows the corresponding liveness evidence, and disables normal root/retained
actions while invariants are transitional.

## QEMU reference acquisition

Build an image containing
`tests/qemu/device-inspector-fixture.toit`, then use:

```sh
TOIT=build/host/sdk/bin/toit
$TOIT compile --snapshot --project-root tests/qemu \
  -o build/esp32/device-inspector.snapshot \
  tests/qemu/device-inspector-fixture.toit
$TOIT tool firmware --envelope=build/esp32/firmware.envelope \
  container install -o build/esp32/device-inspector.envelope \
  inspector build/esp32/device-inspector.snapshot
$TOIT tool firmware --envelope=build/esp32/device-inspector.envelope \
  extract --format=image -o build/esp32/device-inspector.bin
$TOIT tool firmware --envelope=build/esp32/device-inspector.envelope \
  extract --format=elf -o build/esp32/device-inspector.elf

mkdir -p /tmp/toit-inspector-capture
cp tests/qemu/device-inspector-esp32-manifest.json \
  /tmp/toit-inspector-capture/manifest.json
cp build/esp32/device-inspector.elf \
  /tmp/toit-inspector-capture/firmware.elf
cp build/esp32/device-inspector.envelope \
  /tmp/toit-inspector-capture/device-inspector.envelope
cp build/esp32/device-inspector.snapshot \
  /tmp/toit-inspector-capture/device-inspector.snapshot
$TOIT run --project-root tools \
  tools/device-inspector/extract-program-layout.toit -- \
  /tmp/toit-inspector-capture/device-inspector.snapshot \
  /tmp/toit-inspector-capture/program-layout.json
$TOIT run --project-root tools \
  tools/device-inspector/extract-runtime-layout.toit -- \
  gdb /tmp/toit-inspector-capture/firmware.elf \
  /tmp/toit-inspector-capture/runtime-layout.json
tests/qemu/capture-device-inspector.sh \
  /path/to/qemu-system-xtensa esp32 build/esp32/device-inspector.bin \
  /tmp/toit-inspector-capture/manifest.json \
  /tmp/toit-inspector-capture/device.toitdump
$TOIT run --project-root tools \
  tools/device-inspector/verify-qemu-fixture.toit -- \
  /tmp/toit-inspector-capture/device.toitdump
```

The final command is the old-space oracle: it fails unless process group 2 has
decoded old-space objects and the named `old-space-marker` global points into
one of those old-space chunks. The fixture retains ordinary heap objects—not
only an external `ByteArray` payload—so it crosses the VM's survivor threshold
before the second forced collection.

Classic ESP32 QEMU does not add PSRAM by default. To capture its modeled 4 MiB
PSRAM window, use the matching manifest and pass the size explicitly:

```sh
cp tests/qemu/device-inspector-esp32-4m-psram-manifest.json \
  /tmp/toit-inspector-capture/manifest.json
QEMU_PSRAM_SIZE=4M tests/qemu/capture-device-inspector.sh \
  /path/to/qemu-system-xtensa esp32 build/esp32/device-inspector.bin \
  /tmp/toit-inspector-capture/manifest.json \
  /tmp/toit-inspector-capture/device-with-psram.toitdump
```

This proves that acquisition can read the PSRAM aperture. The standard ESP32
firmware configuration has `CONFIG_SPIRAM` disabled, so it does not prove that
Toit has allocated objects there. A semantic PSRAM test also needs a firmware
built with SPIRAM and the Toit SPIRAM heap enabled. The wrapper accepts `2M` or
`4M` for `esp32`, and `2M`, `4M`, `8M`, `16M`, or `32M` for `esp32s3`.

The ESP32-S3 semantic fixture supplies that missing proof. Its helper selects
octal PSRAM, disables the initialization fallback, enables checkpoints, and
builds the fixture artifacts in an isolated directory:

```sh
CCACHE_DIR=/tmp/toit-ccache tests/qemu/build-s3-psram-inspector.sh
TOIT=build/host/sdk/bin/toit
GDB=xtensa-esp32s3-elf-gdb
CAPTURE=/tmp/toit-inspector-s3-psram
mkdir -p "$CAPTURE"
cp tests/qemu/device-inspector-esp32s3-4m-octal-psram-manifest.json \
  "$CAPTURE/manifest.json"
cp build/esp32s3-qemu-psram/device-inspector.elf \
  "$CAPTURE/firmware.elf"
cp build/esp32s3-qemu-psram/device-inspector.envelope \
  "$CAPTURE/device-inspector.envelope"
cp build/esp32s3-qemu-psram/device-inspector.snapshot \
  "$CAPTURE/device-inspector.snapshot"
cp build/esp32s3-qemu-psram/program-layout.json \
  "$CAPTURE/program-layout.json"
cp build/esp32s3-qemu-psram/system.snapshot \
  "$CAPTURE/system.snapshot"
cp build/esp32s3-qemu-psram/system-program-layout.json \
  "$CAPTURE/system-program-layout.json"
$TOIT run --project-root tools \
  tools/device-inspector/extract-runtime-layout.toit -- \
  "$GDB" "$CAPTURE/firmware.elf" "$CAPTURE/runtime-layout.json"
$TOIT run --project-root tools \
  tools/device-inspector/extract-checkpoint-layout.toit -- \
  "$GDB" "$CAPTURE/firmware.elf" "$CAPTURE/checkpoint-layout.json"
QEMU_PSRAM_SIZE=4M QEMU_PSRAM_MODE=octal \
  tests/qemu/capture-device-inspector.sh \
  /path/to/qemu-system-xtensa esp32s3 \
  build/esp32s3-qemu-psram/device-inspector.bin \
  "$CAPTURE/manifest.json" "$CAPTURE/group-2.toitdump" \
  mutator-armed 2
```

The matching QEMU model is selected with its `ssi_psram.is_octal` property.
The firmware fails at startup instead of silently falling back if PSRAM cannot
be initialized. A successful boot reports `using SPIRAM for heap metadata and
heap`. The checked-in 4 MiB manifest records the fixture build's observed MMU
split: flash data ends at `0x3c340000`, where its PSRAM mapping begins. Recheck
that boundary when changing the firmware layout.

### Repeatable runtime checkpoints

For decoder tests, build an opt-in firmware with named runtime checkpoints:

```sh
TOIT_VM_STATE_CHECKPOINTS=1 make esp32
```

The default build has no active checkpoint code. The fixture arms checkpoints
through a debug primitive and forces a full collection. Generate the checkpoint
addresses from the exact ELF, beside the manifest and other attachments:

```sh
$TOIT run --project-root tools \
  tools/device-inspector/extract-checkpoint-layout.toit -- \
  gdb /tmp/toit-inspector-capture/firmware.elf \
  /tmp/toit-inspector-capture/checkpoint-layout.json
tests/qemu/capture-device-inspector.sh \
  /path/to/qemu-system-xtensa esp32 build/esp32/device-inspector.bin \
  /tmp/toit-inspector-capture/manifest.json \
  /tmp/toit-inspector-capture/device.toitdump \
  scavenge-after-forwarding
```

Available names are `mutator-armed`, `scavenge-started`,
`scavenge-after-forwarding`, `scavenge-after-roots`, `scavenge-complete`,
`mark-after-roots`, `mark-complete`, `sweep-started`, `compaction-started`, and
`gc-complete`. Use a fresh QEMU process and capture directory for each member of
a corpus.

Checkpoint mode starts QEMU with `-S`. The Toit GDB client stops first at an
arm gate after firmware initialization, writes the requested checkpoint ID,
then continues to the selected runtime boundary. Acquisition only starts after
the GDB stop reply and QMP's stopped `debug` state agree. The resolved manifest
uses `capture-mode: runtime-checkpoint` and records the requested ID, runtime
context pointer, both raw stop replies, and the ELF-derived checkpoint layout.
These points are stable test oracles, not a prerequisite for arbitrary-stop
analysis. In particular, checkpoints inside collection deliberately describe a
heap whose normal invariants may not hold, so `semantic-coherence` remains
false.

Capture and verify the complete corpus with one command:

```sh
tests/qemu/capture-device-inspector-corpus.sh \
  /path/to/qemu-system-xtensa esp32s3 \
  build/esp32s3-qemu-psram/device-inspector.bin \
  /path/to/exact-fixture-template \
  build/device-inspector-checkpoint-corpus
```

The output directory is resumable. Each checkpoint has a bounded timeout and
uses a fresh QEMU process. The final Toit verifier checks the name, ID, phase,
runtime discovery, forwarding evidence, and mark-bit liveness evidence for all
ten members. The opt-in fixture forces a non-compacting old-space collection
for `sweep-started`; `compaction-started` continues to use the ordinary forced
compacting collection. This override is compiled out with the rest of the
checkpoint instrumentation in normal firmware builds.

### Select one process group

Append a process-group ID after the checkpoint to capture only that container's
owned runtime ranges:

```sh
tests/qemu/capture-device-inspector.sh \
  /path/to/qemu-system-xtensa esp32 build/esp32/device-inspector.bin \
  /tmp/toit-inspector-capture/manifest.json \
  /tmp/toit-inspector-capture/group-2.toitdump \
  mutator-armed 2
```

The current stopped-target planner reads only within the manifest's permitted
memory map. It follows the scheduler's process-group list, then includes the
selected group's process structures, program heaps, global-variable arrays,
old/new-space chunks, and the small VM/list metadata needed to decode them.
Other groups remain visible as `capture-state: omitted`, without producing
missing-memory diagnostics.

This first implementation requires either `mutator-armed` or `gc-complete`,
where the ownership lists and object boundaries are stable. It walks the
selected process heaps and includes raw external byte-array and string payloads
whose heap objects provide exact addresses and lengths. Discovery and ownership
are reported separately: `external_memory_` remains authoritative for bytes
owned by the process, while additional referenced payloads are marked
unaccounted/shared rather than attributed to it.

The planner also traverses the process's intrusive native resource-group and
resource lists. Base metadata, ownership links, state, object notifiers, and
ELF-derived dynamic vtable names are captured. A second bounded layout pass
records the exact full object size for every queryable vtable type; size-only
types retain an unresolved marker because their internal pointer ownership is
not yet declared. Declared dynamic layouts can add type-specific state; the
initial declarations cover simple/ID resources and the timer/notifier path.
Undeclared driver buffers, DMA descriptors, group-owned native memory, and
accounting remainders stay explicit in `capture-scope.unresolved`.
The external-root and object-notifier lists and the runnable, registered
callback, and registered VM-finalizer queues are capture inputs as well.
Finalizer nodes are included at their ELF-derived dynamic size so the offline
root decoder can recover both key and callable-lambda slots without confusing
registered weak keys with strong reachability.

PSRAM is a source-memory capability, not an assumption. A manifest region with
kind `external-ram` or `psram` makes it readable by the same selective planner,
and the artifact records its region IDs. Otherwise `psram-readable` is false
and `psram` remains in `missing-regions`; an external pointer into that range is
reported as outside the source memory map instead of aborting the capture.

The script waits for the fixture marker and controls QEMU through its
machine-readable QMP socket. It stops all virtual CPUs, verifies the paused
state, invokes virtual-address `memsave` through QMP's HMP bridge, and validates
every resulting file size. `pmemsave` reads physical memory and must not be
substituted unless aliases are understood and recorded. Region boundaries are
intentionally supplied by the manifest: they vary by chip and configuration,
and blindly reading gaps or MMIO is invalid.

While QEMU is paused, the acquisition helper first asks the GDB remote stub for
per-core `g` packets and its target-description XML. When target XML is
available, its complete include graph becomes a hashed attachment that defines
the packet layout. The official ESP32 QEMU `v9.2.2-toitlang.2` stub does not
advertise `qXfer:features`; for that release the helper instead obtains
`info registers -a` through QMP's HMP bridge and applies a strict parser
validated against the release. It requires exactly the QMP-reported cores and
the complete PC, PS, and A0–A15 baseline for each, stores all named 32-bit
values, and hashes the untouched HMP output as supporting evidence.

The checked-in classic ESP32 manifest contains the expected QEMU-visible DRAM,
IRAM, RTC fast/slow RAM, and 4 MiB DROM spans, but remains explicitly partial.
DROM is needed to read each program's class-bits table and therefore obtain
exact instance sizes. Confirm all spans against the QEMU machine and firmware
linker map when either changes. IRAM and DRAM can contain physical aliases; the
artifact intentionally records the CPU virtual views.

`stop` produces a hardware-coherent capture, but it may halt the VM in the
middle of bytecode dispatch or garbage collection while interpreter state is
still cached. This fixture establishes the memory map, format, and acquisition
path; it is not yet a proof that every capture can be decoded as a coherent
object graph. Object-graph golden tests need a guest safepoint handshake (or a
single-core fixture stopped at a known runtime boundary).

The QEMU script and acquisition clients are Toit code and target the official
`v9.2.2-toitlang.2` Linux release. Firmware envelopes and the SDK used to
compile installed snapshots must match exactly. On real dual-core hardware,
provenance must only claim a complete capture after both cores are confirmed
stopped. PSRAM coverage is also acquisition-specific and must be marked
missing until verified.

With the released alpha.198 fixture artifacts used during development, the
exact acquisition command is:

```sh
CAPTURE=/tmp/device-inspector-capture
RELEASE=/tmp/toit-envelope-v2.0.0-alpha.198
QEMU=/tmp/toit-qemu-v9.2.2-toitlang.2/qemu-toit-v9.2.2-toitlang.2-linux-x86_64/bin/qemu-system-xtensa
mkdir -p "$CAPTURE"
cp tests/qemu/device-inspector-esp32-manifest.json "$CAPTURE/manifest.json"
cp "$RELEASE/device-inspector.elf" "$CAPTURE/firmware.elf"
cp "$RELEASE/device-inspector.envelope" "$CAPTURE/device-inspector.envelope"
cp "$RELEASE/device-inspector.snapshot" "$CAPTURE/device-inspector.snapshot"
build/host/sdk/bin/toit run --project-root tools \
  tools/device-inspector/extract-program-layout.toit -- \
  "$CAPTURE/device-inspector.snapshot" "$CAPTURE/program-layout.json"
build/host/sdk/bin/toit run --project-root tools \
  tools/device-inspector/extract-runtime-layout.toit -- \
  gdb "$CAPTURE/firmware.elf" "$CAPTURE/runtime-layout.json"
tests/qemu/capture-device-inspector.sh \
  "$QEMU" esp32 "$RELEASE/device-inspector.bin" \
  "$CAPTURE/manifest.json" "$CAPTURE/device.toitdump"
```
