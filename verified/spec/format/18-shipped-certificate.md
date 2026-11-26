# 18. The shipped certificate

Decides note 14's deferred "shipped stack maps": the toolchain ships the
verifier's certificate with the program, and the device only checks it.

## Problem

The structural verifier checks a certificate (`v2::verifier::Cert`): per
method the kinds of the frame's slots at every reachable instruction,
plus block-parameter masks, contexts of block methods, selector
representatives and the pinned maps that other methods look up. Until
now the device computed it itself with an untrusted inference
(`v2/infer.rs`): 66 KB of code, 85 to 90 % of the verification time, and
a peak of about 36 bytes per method plus the largest method's maps (45 KB
for hello world with 758 methods; 431 KB for the toit CLI). The target is
an ESP32 without external RAM, which can afford neither that RAM nor that
flash.

## Decision

* The certificate is produced at compile time on the host, by the same
  inference, and travels with the program: a `certificate` member of the
  snapshot bundle, a trailing block of the image, a trailing block after
  the flash allocation.
* The device reads the global part of the certificate in place (random
  access into memory-mapped flash) and decodes the maps one method at a
  time from a stream, in method order, while the proven checker walks the
  methods. RAM: the maps of one method plus a few words.
* The certificate is untrusted input. `v2::cert::verify_shipped` is proven
  (Verus, no `assume`/`admit`) to return true only if some certificate
  with the given trusted fields is accepted (`accepts`), so
  `theorem_soundness` applies. Decoding is part of the proof's exec code:
  total, bounds-checked, terminating (Verus proves it); a decoding bug can
  only make the checker reject.
* Devices build the verifier without the inference (cargo feature
  `infer` off) and reject untrusted programs without a certificate. Hosts
  keep the inference as a fallback.
* The installer may drop the certificate once the verdict is recorded:
  it costs no flash at run time.

## Alternatives

* **Emit the certificate from the C++ compiler**, which knows stack heights
  and block structure. Rejected: it needs a second implementation of the
  kind rules (block slots, contexts, tokens, parameter origins for block
  parameters, the join at merge points, non-local branch seeds), and the
  compiler does not know the program as the VM loads it (method indices
  from the decoded method table, dispatch offsets, the builtin class ids).
  The inference already exists, is total and fuzzed, and runs on exactly
  the tables the device's checker reads.
* **Link the inference into toit.compile.** toit.compile does not link the
  VM (snapshot reader, `V2MethodTable`, `v2_program_tables`) or the Rust
  library. Chosen instead: toit.compile writes the snapshot, then runs
  `toit.run --certify <snapshot>` (next to it), which loads the snapshot
  exactly as the VM does, infers, encodes, checks the result with
  `verify_shipped`, and rewrites the bundle with the certificate.
  `-Xcertificate=false` skips it. Since version 2 the certificate is made
  for a policy: the untrusted policy's rules and primitive table (`toit.run
  --certify --trusted`: the trusted ones), whose identity its header
  records; the device checks it with the untrusted policy's.
* **Ship maps at every instruction.** Hello world has 11,155 mapped
  instructions; only 214 need shipping (1.9 %). The decoder recomputes the
  rest with the verified transfer function `x_post`.
* **Hold the global part in RAM** (as the inference did, 27 KB for hello
  world). Rejected: the tables are read where they are, in flash.
* **Sparse per-method words** (sorted records for the methods with a block
  parameter or a context, binary search). Smaller (about 2 KB instead of
  3 KB for hello world), but the inference updates the words in place
  during its fixpoint, and the checker reads one representation for both
  paths. Kept dense; revisit if the transfer size matters.

## Encoding

All numbers in the tables are 32-bit little endian. Every read is total:
a word outside its table reads as 0, so any bytes have a meaning, and
`rd`/`fld` in `v2/check.rs` are the specification of the reads.

Header (64 bytes, version 2 since 2026-11-26):

| Offset | Field |
|---|---|
| 0 | magic `0x54524354` ("TCRT") |
| 4 | version, 2 |
| 8 | number of methods (must equal the program's) |
| 12 | policy: the identity of the primitive table the certificate was made for (`cert::policy_id`: 32-bit FNV-1a over the number of modules and, per module, its number of primitives and their arities, 0xff for a denied and 0xfe for an absent primitive) |
| 16 + 8i | section i: offset (from the certificate start), length |

The checker reads the header first (`cert::x_header_error`) and rejects a
certificate of another version, of another method count, made for
another primitive table (policy) or with a section outside it, before it
reads anything else, with the reason (vmverify: "certificate made for
another primitive policy" and so on). The policy is part of the header
only to reject early with a clear message: the verdict is computed with
the table the device passes (the one of the program's policy), whatever
the header says.

Sections (4-byte aligned in what the encoder writes; the decoder does not
need alignment):

| # | Section | Record | Meaning |
|---|---|---|---|
| 0 | method words | 4 B per method | block method (kind 3): its context, 0 = none, j+1 = context record j; other methods: block-parameter mask, bit i = parameter i (parameters from 32 on are never block parameters) |
| 1 | contexts | 12 B: outer method, slot, top node | the context of a block method: its creator, the slot it is created in, the kinds of the creator's frame up to that slot |
| 2 | selectors | 8 B: selector, method | selector representatives, strictly sorted by selector (binary search); no record = -1 |
| 3 | pins | 12 B: method, offset, top node | the maps other methods look up (non-local branch targets, the task entry at offset 1), strictly sorted by (method, offset) |
| 4 | nodes | 12 B: parent, kind word, operand | lists of kinds, bottom first, sharing their bottoms; parent >= own index means none; kind word low 3 bits: 0 value, 1 block parameter, 2 token, 3 method (operand), 4 block of depth `word >> 3` and slot (operand) |
| 5 | maps | stream | per method, in method order (below) |

The checker's views of these tables are exactly the abstract certificate's
global part (`impl View for XGlobal`, `v2/check.rs`); the proofs of
the walk (`v2/walk.rs`) are over those views. The sorted tables are checked to be
sorted once (`x_g_ok`), which the binary searches need.

Maps stream, per method: `count`, then `count` entries of

    delta  drop  push  kind*push

(unsigned LEB128, at most 5 bytes each, below 2^32). `delta` is the
entry's offset (first entry) or its distance minus one from the previous
entry's offset; the entry's kinds are the previous placed map with `drop`
slots popped and the `push` kinds pushed. A kind is a number whose low 2
bits are a tag: 0 value / block parameter / token (rest 0, 1, 2), 1 method
(rest = id), 2 block of depth 0 (rest = slot), 3 block of the depth that
follows as another number (rest = slot).

Checking one method (`v2::walk::walk_method`, the single-pass checker
since 2026-11-26): a block method without a context has no maps (`count`
must be 0). Otherwise walk from offset 0 with the entry kinds: at each
offset place the shipped map if one is given there (it must equal the
successor kinds of the previous instruction if that one falls through),
else those successor kinds (`x_post`, the checker's own transfer
function), else jump to the next shipped offset; check the instruction on
the placed kinds and step by its length (an invalid opcode or an
instruction crossing the end rejects). Forward branch and HASH_FIND
targets are compared when the walk places them, backward targets against
the kinds kept when the walk passed them. Shipped maps behind the walk are
read and ignored; a shipped list longer than the method's frame bound
rejects (that bounds what a malformed stream can make the checker
allocate). The encoder (`v2/encode.rs`, host) walks each method
the same way and ships a map exactly where the inferred map differs from
what the walk would place.

## What is proven

`v2/cert.rs`:

```rust
pub fn verify_shipped(p: &VProgram, cert: &[u8], global_count: u64,
                      prim_arity: &[Vec<u8>], trusted: bool) -> (r: Result<(bool, usize, usize), Oom>)
    ensures
        r matches Ok(r) ==> r.0 ==> exists|c: Cert| accepts(vview(p), c, trusted)
            && c.global_count == global_count as int
            && c.prim_arity == prim_view(prim_arity@),
```

It checks the header, makes an `XGlobal` that borrows the certificate's
sections and hands it with the maps stream to `v2::walk::walk`, which is
proven to return true only if `g_ok(g) && split_ok(vview(p), g@, ms,
trusted)` holds for the ghost maps `ms` it builds while it walks; and
`lemma_split_sound` turns `split_ok` into `accepts` of `with_maps(g@, ms)`.
(Until 2026-11-26 a decoder produced the maps first and `check::verify`
checked them: two passes.) The trusted fields (the globals' count, the
primitive table of the program's policy) are the caller's, not the
certificate's; the heap check
(`x_loaded_ok_stream`) proves `loaded_ok` for every certificate with that
global count, so `theorem_soundness` applies to the witness.

Soundness does not depend on the stream's decoding computing anything in
particular: the walk checks every instruction it places. Completeness for
compiler output is tested (below), not proven.

## Where it lives

* **Snapshot bundle**: an ar member named `certificate`, after `uuid` and
  `source-map` (forward-only readers of the earlier members are not
  affected). The bundle's uuid does not cover it. `SnapshotBundle::
  stripped()` keeps it; `with_certificate` replaces it.
  `tools/snapshot.toit` (`SnapshotBundle.certificate`, class
  `Certificate`) and `toitp --certificate` show it.
* **Launching a snapshot** (`snapshot.launch`, the host's `toit.run`): the
  system process passes the bundle's member as the primitive's sixth
  argument; `toit.run --verify` uses it (`--no-certificate`,
  `--require-certificate`).
* **Image** (`toit tool snapshot-to-image`): after the relocatable program
  and the assets (if any), a trailing block

      u32 marker 0x31424354 ("TCB1")   u32 length   certificate   padding to 4096

  encoded like the assets (relocation words of 0). `--no-certificate`
  leaves it out. The image id does not cover it.
* **Flash** (installing an image: `ContainerImageWriter`,
  `src/resources/image.cc`): the installer reserves and writes the whole
  image, so the block lands right after the program's allocation:
  `writer_commit` does not count a block that starts with the marker as
  assets. `FlashAllocation::size()` (program pages plus the padded assets)
  does not include it.

### What the installer does (coordination with `phase5/portability`)

Implemented (branch device/certificate-and-size): both commit paths
(`image.writer-commit`, `flash_registry.allocate`) follow the steps below,
erasing the block before the header is written; verified/vmverify/README.md
"Where it runs" has the details and the test.

1. Locate: `end = allocation + allocation->size()` (after the assets if the
   allocation has them). If `end + 8` is inside the flash registry
   (`FlashRegistry::allocations_size()`) and the word at `end` is the
   marker `0x31424354`, the certificate is the `length` bytes at `end + 8`
   (check `end + 8 + length` against the registry's end). Anything else:
   no certificate, and an untrusted program is rejected.
2. Verify before the program is used: pass the bytes as
   `toit_vmverify_input.certificate`/`certificate_length` (src/
   verifier_v2.h; `V2Verifier::verify(program, table, trusted,
   certificate, length)`, `Verifier::verify_for_policy(..., certificate,
   length)`). The safest place is `writer_commit` before the header is
   written (a rejected program never becomes a valid allocation; the
   program is complete in flash at that point, the header is in RAM).
3. Record the verdict, then drop the block: erase its pages
   (`flash.erase`, whole pages from `end` for `round_up(8 + length,
   4096)`). They become an ordinary hole. Until then the pages are already
   outside every allocation: a registry rescan treats them as a hole, so
   the block must not be relied on after the install finishes (verify at
   install, not at a later spawn), and nothing else needs to free them.
4. A rescan of a hole accepts any page with a valid allocation header, so
   data left in a hole could pose as an allocation. Freed allocations (and
   their assets) already leave arbitrary data behind (`free` erases only
   the header page); erasing the certificate pages on drop keeps the
   certificate from adding to that. Recommendation for the registry
   (outside this note): erase holes before trusting a header in them, or
   keep verdicts with the allocation.

Spawning from flash never looks for the block (it is gone): images flagged
untrusted carry the install-time verdict (taken only if it is of the
running firmware's verification epoch, verified/verification-epoch.cmake;
else the image is refused until it is reinstalled); others started untrusted are
verified on spawn, which on hosts infers (`FlashRegistry::is_verified`
caches the verdict) and on devices rejects.

## Versioning

The header's version (2; 1 had no policy field) changes with any change
of the encoding or of the meaning of the tables; a device rejects a certificate whose magic or
version it does not know (and then an untrusted program without a usable
certificate). The certificate is computed from the program as the VM loads
it, so it also depends on the bytecode format and the primitive table;
both are part of the SDK version recorded in the bundle. A program
installed with a certificate the device cannot read is rejected, never
run unverified; re-certifying needs only the snapshot (`toit.run
--certify`).

## Sizes and cost

See verified/vmverify/README.md, "Shipped certificates", for the table
(certificate size, its fraction of the bytecodes, verifier RAM and time
with a shipped certificate against the inference). Hello world (758
methods, 23.9 KB of bytecodes): 9.9 KB certificate (41 %: method words
3.0 KB, contexts 1.7 KB, selectors 1.3 KB, nodes 2.4 KB, maps stream 1.4 KB
for 214 shipped maps, about 6.6 bytes per shipped map); checker peak 6 KB
of Rust heap instead of 30 KB, 13 ms instead of 41 ms (dump path).
