# `.toitdump` format version 1

All integer fields in the 16-byte prefix are little-endian:

| Offset | Size | Meaning |
| ---: | ---: | --- |
| 0 | 8 | ASCII `TOITDUMP` |
| 8 | 4 | Format version (`1`) |
| 12 | 4 | JSON header size |
| 16 | variable | UTF-8 JSON header |
| following | variable | Concatenated region payloads |

Region `payload-offset` values are relative to the first byte following the
JSON header. CPU addresses are lowercase hexadecimal strings with a `0x`
prefix; counts and byte sizes are JSON integers. Each region has a SHA-256
checksum. Readers reject truncated, overlapping, or checksum-invalid regions.

The header contains:

- `format`, `format-version`, and a content-derived `id`;
- `target`, including chip, architecture, word size, and byte order when known;
- `completeness`, whose `state` is either `complete` or `partial`;
- `provenance`, describing acquisition, QEMU/debugger version, firmware ELF,
  envelope, snapshots, and their identities when available;
- `regions`, with stable IDs, CPU virtual addresses, sizes, kinds,
  permissions, payload offsets, and checksums.

Version 1 also permits five optional header fields:

- `attachments` identifies external firmware ELFs, envelopes, snapshots, GDB
  target descriptions, or later evidence by ID, kind, name, size, and SHA-256;
- `register-sets` stores either an exact GDB-encoded register packet per core
  with an attachment defining its layout, or a validated named 32-bit map with
  the untouched debugger output identified as its source attachment when one
  exists. Register evidence carried directly by an acquisition protocol does
  not require an external source attachment;
- `runtime-layout` embeds the small, exact DWARF-derived C++ type layout and
  static-root addresses. It names and includes the SHA-256 of its source ELF
  attachment, and is itself covered by the capture ID;
- `program-layouts` embeds method boundaries, class identities, source
  positions, the dispatch table, and opcode names, sizes, and formats extracted
  from exact Toit snapshots. Each layout is bound to a
  snapshot attachment checksum and to the checksum of its program bytecodes;
- `capture-scope` identifies either a `full-device` capture or a selective
  `process-group` capture. Selective scope records the chosen group, included
  bootstrap and owned ranges, omitted groups, and unresolved external/shared
  dependencies. Missing addresses outside that declared evidence set mean “not
  captured,” not corrupt memory.

The format deliberately separates the wire acquisition protocol from the
normalized artifact. QEMU `memsave`, GDB, JTAG, and the UART `TDM1` stream can
all feed the same importer boundary. Acquisition-specific records remain
metadata rather than requiring source-specific HTTP endpoints.

UART `TDM1` imports retain acquisition details without changing the container
layout. Capture provenance contains the raw info/end fields and parser
diagnostics. Each region has a `transport` object containing its numeric region
ID, kind, flags, and chunk count. Capture completeness separately records
transport completion, stable partial-reason codes, asynchronous capture mode,
and semantic coherence. All `.toitdump` integrity checks cover this metadata as
part of the content-derived capture ID.

Valid `TDM1` CPU evidence frames become `named-uint32-map` register sets with
source `uart-tdm1`. Their metadata retains the wire sequence, numeric frame
flags, `volatile` and `partial` booleans, and both the numeric and named capture
provenance. Generic register names are `PC`, `SP`, `STATUS`, `CAUSE`, and
`FAULT_ADDRESS`; architecture-specific names are `SAR` and `A0` through `A15`
for Xtensa, and `X0` through `X31` for RISC-V. Missing names remain missing and
must not be interpreted as zero. Malformed frames and a second frame for an
already represented core are excluded and recorded as partial-capture reasons.

A UART semantic-metadata input may contribute immutable memory regions from a
checksum-bound ESP application-image attachment. Its validated DROM segments
are stored in the normalized capture as `flash-mapped-data`; this is offline
target data, not UART acquisition evidence, and does not change the received
region counts or transport-completeness result.

Version 1 stores one capture per file and does not embed external attachment
contents. The optional attachment identities, register sets, runtime and
program layouts, and capture scope are covered by the content-derived capture
ID. Readers remain compatible with earlier version 1 files where these fields
are absent.
