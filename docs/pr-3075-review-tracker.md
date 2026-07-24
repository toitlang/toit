# PR #3075 review tracker

This document tracks Florian's pending review comments on
[toitlang/toit#3075](https://github.com/toitlang/toit/pull/3075). It is based
on each comment's preserved `original_commit_id`, not GitHub's mutable current
`commit_id`.

Review baseline: local `floitsch/ec618` at `ce3dd02c`.

## Status legend

- **Open** — current code or documentation still needs work.
- **Audit** — the attached line may be fixed, but the comment states a broader
  rule that must be checked across the relevant code.
- **Discuss** — a design choice, missing evidence, or explicit request for
  discussion needs Florian's input.
- **Resolved** — the current tree addresses the comment.
- **Superseded** — later work removed or replaced the reviewed implementation,
  so the original request no longer applies.
- **Upstream** — the request belongs in a separate upstream change rather than
  this EC618 pull request.

## Review method

For every comment:

1. Use `original_commit_id` to recover the exact reviewed commit and diff.
2. Check all later commits and the current local tree for the requested change.
3. Treat wording such as “same elsewhere”, “all primitives”, and “use this
   convention” as an audit scope rather than a one-line request.
4. A rewrite is not evidence that a comment was addressed. Follow the
   behavior into the replacement, and audit analogous files whenever the
   comment states or implies a general rule.
5. Use **Superseded** only when the underlying behavior or concept is
   genuinely gone. Moving, renaming, or reimplementing it does not qualify.
6. Record explicit discussion requests and unresolved assumptions before
   finalizing the work plan.

## Questions and design discussions

These are the items where implementing a plausible interpretation would make
a product or hardware-policy decision. Decisions from the first discussion
are recorded in place; the remaining questions stay open.

### 1. How should EC618 base images be distributed?

Comments
[r3609289997](https://github.com/toitlang/toit/pull/3075#discussion_r3609289997)
and
[r3647488497](https://github.com/toitlang/toit/pull/3075#discussion_r3647488497)
ask how the flasher obtains the matching base, how several base versions
coexist, and whether bases should live in a separate repository or in
envelopes.

The current workflow publishes immutable `ec618-base-vN` GitHub releases in
`toitlang/toit`, while local tooling expects the selected artifact in
`EC618_BASE_DIR`. That is enough for a developer workflow, but it does not yet
define the envelope/flasher contract.

**Decision:** every EC618 envelope is self-contained and carries its exact
base. The envelopes repository releases one envelope for each base that is
actually supported and maintains the explicit list of supported base
versions. Initially that list contains one base; an older/additional base is
added when there is a concrete user request. Users never need to discover or
download a base separately. A statically flashed envelope therefore cannot
have an internal base mismatch.

An OTA image extracted from an envelope should be checked against the target
device's base before transfer, but that preflight belongs to Jaguar. On-device
OTA must independently ensure that it never activates a slot whose base ID
does not match the installed base. Updating the frozen base over OTA has been
investigated and is not feasible; there is no base-update path to design or
expose, only rejection of an incompatible slot.

### 2. Is console/partition configuration device state or OTA-image state?

Comments
[r3626188228](https://github.com/toitlang/toit/pull/3075#discussion_r3626188228),
[r3626200014](https://github.com/toitlang/toit/pull/3075#discussion_r3626200014),
and
[r3626217943](https://github.com/toitlang/toit/pull/3075#discussion_r3626217943)
describe console selection and partition changes as properties of an OTA
image, committed and rolled back atomically with that image.

The current anchor is deliberately per-device state: `set-console-uart`
survives OTA, reset, and slot rollback, and provisioning can retarget the data
layout independently of a slot.

**Decision:** console and partition configuration are transactional properties
of an OTA image. Changes are written only to the inactive/staging slot, and
selecting or rolling back a slot selects or rolls back its console and
partition view too. Only immutable discovery information remains
device-global.

Do not expose partition-size/layout changes in the initial OTA API: reject an
update whose partition geometry differs from the active image. Keep the
transaction/migration representation and its tests capable of supporting a
future, explicitly enabled partition migration. Those tests are what make it
possible to ship a migration-aware OTA later; their existence must not make
the unsafe operation available now.

### 3. What should GPIO ownership mean across deep sleep?

[r3647379232](https://github.com/toitlang/toit/pull/3075#discussion_r3647379232)
requests a design discussion for pin hold/release. The current implementation
has no EC618 hold operation; deep sleep tears the VM down, the always-on IO
supply is powered down, and the public documentation nevertheless says AON
pads keep working in sleep. The mismatch remains even though the GPIO code was
rewritten.

**Decision:** distinguish normal resource ownership from explicit deep-sleep
wake configuration. Normal GPIO/peripheral reservations end with the
container/VM. The wake API must accept/document physical `gpio.Pin` values and
state exactly which pins are wake-capable, including the corresponding EC618
GPIO names:

- PAD40 / `Ec618.gpio 20` maps to wakeup input 3.
- PAD41 / `Ec618.gpio 21` maps to wakeup input 4.
- PAD42 / `Ec618.gpio 22` maps to wakeup input 5.

The implementation must reject other ordinary GPIO pins instead of exposing
the PMU's unrelated numeric wakeup index. The pad-based API is canonical, but
provide a convenience conversion from an EC618 GPIO index for users bringing
number-based code from another platform. The dedicated WAKEUP0–2 package pins
do not currently have a normal `gpio.Pin` representation and remain outside
this initial ordinary-GPIO API. Output hold remains a separate future API
after SDK/hardware proof.

### 4. Which hardware rewiring and measurements are available?

This was two separate comments:

1. [r3516664910](https://github.com/toitlang/toit/pull/3075#discussion_r3516664910)
   is specifically about testing `Ec618.spi1`. The EC618 documentation and
   multiple SDK configurations confirm a valid SPI1 mapping of SSN=PAD27,
   MOSI=PAD28, MISO=PAD29, and CLK=PAD30 using ALT1. The board pinout labels
   PAD29/PAD30 only as DBG UART because it presents the normal board use and
   warns against reclaiming the debug UART; it also explicitly says CSDK can
   adjust the mux.

   There is a real current-tree inconsistency to fix before rewiring:
   `Ec618.spi1` and `spi_ec618.cc` accept PAD28/29/30, while this project's
   `RTE_Device.h` initializes SPI1 on the alternative valid ALT3 mapping
   SSN=PAD13, MOSI=PAD14, MISO=PAD15, CLK=PAD16. The CMSIS SPI driver consumes
   those RTE definitions, so the advertised PAD28/29/30 API has not actually
   selected the pins it claims.

   Choose one mapping consistently. PAD28/29/30 is the preferred hardware-test
   mapping because it is the documented default and is exposed as the UART0
   cluster on `modest-affair`. After correcting `RTE_Device.h` and auditing
   the driver's hardware-SSN behavior, the test setup is:

   - transactionally select UART1 as the console;
   - move the USB UART adapter to UART1 TX/RX (PAD34/PAD33);
   - wire the former UART0 pins PAD28/PAD29/PAD30, plus a GPIO CS, to the
     ESP32 and use those physical wires as SPI1;
   - run an ESP32 SPI peer/checker and exercise the same transfer shapes and
     cleanup cases as SPI0.

   “Connect UART0 to the ESP32” therefore means connecting the physical UART0
   pad cluster and remuxing it as SPI1; UART0 is not also used as a control
   UART during the test. Do not rewire until the software mapping is fixed.

2. [r3634553044](https://github.com/toitlang/toit/pull/3075#discussion_r3634553044)
   requests an I2C electrical/failure matrix. The existing I2C0 wires already
   connect PAD13/PAD14 to ESP32 IO17/IO18, so this should not require a manual
   rewire. The ESP32 can command three states over the control UART:

   - both sides' pulls disabled: an I2C operation must fail/return promptly,
     not hang, and the next operation must recover;
   - EC618 internal pulls enabled, ESP32 pulls disabled: NACK probes/transfers
     complete normally;
   - EC618 pulls disabled, ESP32 input pull-ups enabled: the same operations
     complete using only the external peer's pulls.

   This can use an absent address, so it does not require an ESP32 I2C-client
   implementation or the sensor breakout. Confirm that this matches the
   requested test.

### 5. Is Clang support a requirement for this PR?

[r3609295035](https://github.com/toitlang/toit/pull/3075#discussion_r3609295035)
asks whether the EC618 toolchain can use Clang. The frozen vendor base is tied
to the xmake-pinned GCC 10.3 toolchain, while slot code currently uses
Arm GNU 16. Supporting Clang is possible only after verifying ABI, linker,
builtins, and relocation compatibility with that frozen base.

**Decision:** start by using the SDK-pinned Arm GNU 10.3 toolchain consistently
for the base, VM compilation, slot link, and ELF utilities. The current stack
is less clean: xmake pins GNU 10.3, while CMake and the final slot link use
whichever `arm-none-eabi-g++` is on `PATH`.

Clang can target Cortex-M3, but this SDK uses GCC's FreeRTOS port, GNU linker
scripts, GNU-named prebuilt libraries, newlib/libstdc++, libgcc helpers, and
GNU ELF utilities. A Clang build would initially still need most of the GNU
toolchain as its sysroot/runtime/binutils, so it would not yet be easier to
install. The vendor archives are themselves mixed: the private PLAT/PS
archives identify GCC 10.2.1, while the rebuilt/open PLAT archives identify
GCC 10.3.1. Thus the SDK-pinned compiler is not an exact match for every
archive, but it is the vendor's intended integration toolchain. Validate that
combination first. A newer GCC and Clang remain pre-release qualification
work that must be revisited before publishing the first base, not mixed into
the initial cleanup.

### 6. Where should the partition JSON schema be published?

[r3617677392](https://github.com/toitlang/toit/pull/3075#discussion_r3617677392)
requests a schema and suggests a Toit-hosted URL. No schema currently exists.

**Decision:** `toit.io/schemas` is the canonical host. Proposed full schema ID:
`https://toit.io/schemas/ec618/partition-table/v1.json`. “Partition table”
describes the complete document more accurately than singular “partition”.
Keep a matching repository copy for tests. The proposed path name is accepted.

### 7. Is `self-linux` intentional for the base release?

[r3609284626](https://github.com/toitlang/toit/pull/3075#discussion_r3609284626)
asks why the release job uses `self-linux`. Nothing in the workflow explains
an internal-runner dependency, and the normal setup action is not used.

**Decision:** use `ubuntu-latest`; there is no intended self-hosted-runner
dependency. Bootstrap and pin every required tool. Also check whether EC618
can build on the same non-Linux platforms already supported by the ESP32
build, and strive for platform parity rather than introducing a permanent
Linux-only exception. Run the Windows/macOS portability experiments on a
dedicated branch and worktree so slow CI can proceed between the other
current-stack fixes without repeatedly switching the main checkout. Keep
those exploratory commits isolated until a platform result is understood,
then bring back only a coherent reviewed change.

## Technical questions answered by the audit

- GitHub has not lost the reviewed-commit information: all 377 comments have
  a valid `original_commit_id`, and all 140 referenced commits exist locally.
- The EC618 SDK supports forcing code into RAM through `PLAT_PA_RAMCODE` and
  `PLAT_FM_RAMCODE`; its UART IRQ/DMA paths already use those attributes.
  The surviving question is which Toit-owned flash-critical functions need
  the same placement and how the slot linker preserves the relevant sections.
- A slot link uses the chosen `base.elf` as an absolute-symbol provider and
  also links its own runtime archives. Thus an ordinary helper absent from the
  base can be pulled into the slot when it is position-independent and
  available in those archives. A genuinely PLAT-owned function, fixed-region
  callback, or new symbol that must be exported by the frozen base still
  requires a new base. The build should make this distinction explicit with
  an exported-ABI manifest and fail at link/check time, rather than maintain a
  hand-written “known missing” allow-list.
- Inlining within the slot remains available to the compiler. There is no
  cross-image LTO/inlining through the frozen base boundary. The runtime jump
  table was removed in `8d7dfb01`: non-inlined VM-to-PLAT calls link directly
  to the selected `base.elf` symbols through `--just-symbols`. Escaping Thumb
  branches are recorded in the SRL3 table and their immediates are adjusted
  when the slot is relocated. The base identity check must therefore guarantee
  that an image is installed only with the exact base against which it linked.
- The RTC-memory suspicion was correct: the SDK owns a hibernation backup
  application sector. The current implementation uses it, so the earlier
  manually invented reservation is no longer needed.
- The later multimeter result supersedes the assumption that the two GPIO11
  labels expose independent chip pads: they are one mirrored board net. It
  does not supersede alternate-pad support for GPIOs whose chip mux really
  offers alternatives.

## Implementation plan

The decisions above change a few details, but the following workstreams are
already clear from the complete comment pass.

1. **Address review points on the current stack.**
   Do not rebase yet. Implement one coherent addressed point at a time,
   commit it with the relevant tracker/GitHub comment links, and push it so
   the delta against the current stack can be reviewed. Broad rules such as a
   Toitdoc sweep or shared resource ownership may be one logically atomic
   commit, but must not be mixed with unrelated cleanup.

2. **Build one shared EC618 ownership model.**
   Add locked pools for pads, GPIO controller bits, UART/I2C/SPI controllers,
   PWM timers, and ADC channels. A peripheral acquisition must reserve all of
   its resources atomically, release them on every allocation/hardware failure,
   and release/return pads to a safe state when a container dies. Bus-clear
   may temporarily use a reserved pad's GPIO controller only while holding the
   same pool lock, so no other container can observe a transient free resource.
   Apply this model to all peripheral files, not only the GPIO and I2C lines
   on which it was requested.

3. **Finish asynchronous operation and cancellation contracts.**
   Remove library-internal arbitrary timeouts from I2C and SPI. Make external
   cancellation run an unconditional `finally` cleanup/abort. Remove obsolete
   synchronous fallbacks, avoid allocation after hardware has begun an
   irreversible operation, and do no unbounded polling or spinning in a
   primitive/IRQ. Preserve UART's useful DMA staging, but make progress and
   line-idle event driven, cover close-during-transfer, coalesce error events,
   and support break consistently. Stream large SPI and OTA relocation data
   where practical rather than copying an entire operation.

4. **Repair lifecycle bugs before extending features.**
   Register ADC resources, serialize conversion/trim initialization, and
   decide whether conversion latency warrants an event-driven primitive.
   Move PWM cleanup and timer/pad ownership to the channel resource, verify a
   true 100% duty implementation or document a supported limitation, and
   switch off the AON IO supply only when no retained user remains. Make the
   modem connection resource's one-connection/lifecycle contract explicit.
   Guard OTA/relocation state with a resource so only one container can update
   and abnormal container exit aborts and frees the transaction.

5. **Resolve OTA/base/anchor semantics.**
   Implement the decisions in questions 1 and 2. Make the base identity and
   required symbol set compile/link-time inputs. Jaguar should preflight an
   OTA extracted from an envelope; independently, the device must never
   activate a slot for a different base. Do not implement base OTA. Reject
   partition-geometry changes in the initial public OTA path while retaining
   and testing the transactional machinery needed for a future explicit
   migration. Remove unreleased legacy formats, and derive geometry/constants
   from the descriptor or linker symbols rather than duplicating them. Give
   records an unambiguous locator/sentinel and keep partition schema,
   generator, dispatcher, provisioner, envelope, and firmware service on one
   versioned contract.

6. **Harden the platform runtime.**
   Use the most precise stable monotonic EC618 clock available; document any
   remaining tick precision limit. Remove races in entropy and program-memory
   lazy initialization. Factor genuinely common FreeRTOS behavior with ESP32
   where it makes the semantics clearer. Implement long deep sleep without
   running Toit between two-hour hardware intervals. Rework the watchdog to
   the requested scheduler/light-sleep deadline model, keeping only a hardware
   backstop, and remove bring-up-only fatal/scope/debug primitives unless
   explicitly configured.

7. **Normalize public EC618 APIs and documentation.**
   On the current stack, keep EC618 board-name-to-pad translation in `Ec618`
   and use physical `gpio.Pin` values for wake configuration, with a
   convenience conversion from an EC618 GPIO index. During the later rebase,
   adopt integer GPIO identifiers at the common peripheral APIs. Split wake
   enable/disable operations, validate every enum and unsupported option
   eagerly, and place private primitives at file ends.
   Correct Toitdoc across every changed library, tool, and test—not merely the
   commented examples. Move EC618-specific restrictions out of generic UART
   docs, remove stale chip-codename/1.8 V/build-time-console claims, and use
   `2026 Toit contributors` on every new 2026-owned file.

8. **Consolidate tools and build setup.**
   Use `cli.ui`/`ui.abort` consistently, shared parsing/range/CRC helpers, file
   options supplied by `cli`, standard JSON output helpers, and actionable
   parse examples. Resolve external tools before writing output or temporary
   artifacts. Initialize only the submodules required by the selected build,
   explain why the EC618 RTE config is project-local, and eliminate copied or
   generated sources that can silently drift from their authority. Pin the
   SDK's GNU 10.3 toolchain across xmake, CMake, linking, and ELF utilities;
   validate it with both the GCC 10.2.1 and 10.3.1 vendor archive sets. Keep
   Windows/macOS CI experiments on a separate worktree/branch so they can run
   between the other point-by-point fixes.

9. **Replace bring-up scripts with a deterministic hardware suite.**
   Let the ESP32 orchestrate through a control UART, switch control lanes when
   testing a UART's pins, and replace sleeps/floating-input assumptions with
   explicit handshakes and framed/checksummed messages. Share rig wiring by
   function and share protocol/helper code across paired EC618/ESP32 tests.
   Catch only expected timeout exceptions. Cover resource contention between
   containers, cleanup on container death, continuous/overflow UART RX,
   1-off-buffer UART writes, gap-free TX, close while sending, I2C no-pull-up
   and clock-stretch cases, both I2C controllers, SPI1, GPIO alternate pads,
   pull-down, wake/disable/re-sleep, PWM cleanup/100%, ADC contention, OTA
   interruption/rollback, and shifted layouts.

10. **Delete review archaeology from the shipped surface.**
    Retain only durable hardware constraints and explanations that prevent a
    tempting wrong implementation. Remove experiment/scope/repro programs once
    their behavior is covered by deterministic tests, remove obsolete
    bring-up plans and duplicated file inventories, and rewrite source
    comments so they explain the current invariant rather than the sequence of
    failed attempts. In particular, remove the surviving generated
    `plat_jt.h` after verifying it has no consumers, and replace stale
    jump-table descriptions in source comments, READMEs, and OTA/partition
    design documents with the direct-link plus SRL3 relocation design. Do not
    confuse the unrelated libc time `--wrap` shims with the deleted runtime
    jump table. This is a repository-wide audit over the PR's changed files.

11. **Validate in layers.**
    Run formatting and `toit analyze`, host unit/ctests for anchor and
    relocation edge cases, normal host/ESP32 build coverage for shared-file
    changes, EC618 base and slot builds with missing-symbol checks, envelope
    round trips, and finally the deterministic hardware matrix. Re-audit every
    ledger entry after the rebase and test fixes before resolving the GitHub
    review.

12. **Prepare and perform the history transition as a second stage.**
    Once the current-stack fixes have been reviewed, squash the 350+ historical
    bring-up commits into a small, logical EC618 series while preserving the
    review tracker as the mapping from old comments/commits to final changes.
    Only then rebase that clean series onto `origin/master`. During the rebase,
    adapt rather than overwrite the upstream GPIO-number/resource-pool API,
    `uart.Port.console`, the improved FreeRTOS condition variables from #3094,
    and the partial-write refill fix from #3095. Re-run the full ledger audit
    after the rebase because upstream replacements can still expose the same
    issues.

## Audit findings by workstream

These findings summarize the current tree. “Resolved” applies only to the
specific behavior named; a related general-audit item can remain open.

| Area | Status | Current finding |
| --- | --- | --- |
| Original commit mapping | **Resolved** | All 377 comments retain `original_commit_id`; 140 distinct reviewed commits are recoverable. |
| Copyright/name cleanup | **Resolved** | The three explicitly commented files use the requested 2026 contributor header, and the former chip codename no longer appears in the current tree. |
| Toitdoc/conventions | **Resolved** | Audited every PR-added Toitdoc, not just the attached lines: library comments follow imports, continuation paragraphs are indented, examples use fenced code blocks, EC618 UART detail lives in `lib/ec618`, function comments in `mini-jag` are Toitdocs, and all edited sources pass `toit analyze` plus documentation generation. |
| Generic catch/CLI guidance | **Audit** | Catch-alls that can mask unexpected failures and hand-written print/exit/fail paths remain in tests and tools. |
| GPIO/pad ownership | **Open** | The rewrite cleans resources up, but it has no locked pad/GPIO-bit pools and can let two resources claim aliases of the same controller. |
| ADC | **Open** | No exclusivity pool; the newly allocated resource is not registered; conversion and one-time trim state are unsynchronized; conversion busy-polls in a primitive. |
| PWM | **Open** | Teardown now exists, but unlocked static timer ownership and unreserved pads remain. A requested factor of 1.0 still emits a short low notch. |
| I2C | **Open** | Async IRQ operation exists, but arbitrary timeouts, sync fallbacks, post-hardware allocations, IRQ spinning, a 512-byte cap, and unsafe alternate-pad bus-clear ownership remain. |
| SPI | **Open** | Teardown now stops the engine and releases CS/DC, but controller/pad ownership, cancellation, internal timeout, and full-transfer copying remain. The documented PAD28/29/30 SPI1 route is real, but the public helper accepts that route while this build's RTE initializes the alternative PAD14/15/16 route; make the mapping consistent before hardware proof or rewiring. |
| UART | **Open** | Heap rings, DMA TX/RX, two-piece ring copies, and most teardown concerns are addressed. Pools, error coalescing, break parity, event-driven flush, safe print-UART close, and exact boundary tests remain. |
| Cellular | **Audit** | Each connect still creates another event resource while toggling one global modem. The intended cardinality and cleanup semantics need to be made explicit and tested. |
| OTA/slot relocation | **Open** | The old implementation was rewritten, but transaction state is still process-global and not resource-guarded, and relocation still copies full chunks. The contract is now settled: no OTA base update; never activate a base-mismatched slot; reject partition-geometry changes initially; retain tested transactional migration machinery for future explicit use. |
| RTC memory | **Resolved** | It now uses the SDK-managed hibernation backup application sector rather than inventing a second flash reservation. |
| FreeRTOS/runtime | **Open** | Hardware RNG is used and timed-wait rounding was repaired. Tick precision, common-code factoring, #3094 parity, lazy-init races, long sleep, and watchdog semantics remain. |
| Envelopes/firmware tool | **Audit** | Platform subcommands and separate format constants now exist, but unreleased legacy paths and detect-before-write behavior remain; EC618 flashing locates `ectool` only after creating/writing a temporary image. |
| Partition/base tools | **Open** | The anchor rename is complete, but the accepted `https://toit.io/schemas/ec618/partition-table/v1.json` schema does not exist; descriptor/record semantics still need implementation; partition-size changes must remain unavailable; CLI/style rules remain across both surviving and replacement tools. |
| Build setup | **Open** | The shared action still recursively initializes every submodule. Replace `self-linux` with `ubuntu-latest`, pin the SDK GNU 10.3 tools consistently, and explore Windows/macOS parity on an isolated CI branch/worktree. Prebuilt vendor archives contain both GCC 10.2.1 and 10.3.1 objects, which must be covered by compatibility validation. |
| Hardware tests | **Open** | Many later tests are better, but timing, duplicate protocols, swallowed exceptions, bring-up files, external-document references, and incomplete contention/cancellation cases remain across the suite. |
| Historical comments/docs | **Audit** | Extensive experiment chronology and stale issue/file references remain in production source, tests, and more than one overlapping status document. Several source comments and design documents still claim VM-to-PLAT calls use `g_plat_jt`, and the generated `plat_jt.h` survives despite the jump table's removal in `8d7dfb01`; audit and remove this archaeology without deleting the unrelated libc time wrappers. |

## Rewrite follow-through

| Reviewed implementation | Current implementation | Inherited review requirement |
| --- | --- | --- |
| `build-dual-image.toit`, `check-slot-pic.toit`, `gen-partitions.toit`, old `gen-plat-jt` implementations | `provision.toit`, `partitions.toit`, `gen-anchor.toit`, `gen-slot-reloc.toit`, `gen-slot-ld.toit`, `firmware.toit` | Re-audit CLI aborts, shared parsing/CRC/range helpers, examples, nullable style, authority of constants, and removal of references to deleted tools. |
| Runtime `g_plat_jt`, generated stubs, and linker wrapping | Direct symbol resolution against the selected `base.elf` via `--just-symbols`, with escaping Thumb branches represented in SRL3 | Preserve exact base/image compatibility, verify every cross-boundary direct branch is relocatable, and remove the obsolete generated header plus stale jump-table descriptions throughout source and documentation. |
| Early slot marker and fixed slot addresses | Versioned anchor plus relocation trailer | Preserve movable-layout intent, atomic update/rollback, symbol-derived geometry, bounds/signedness checks, and resource-guarded cleanup. |
| Synchronous/blob UART implementations | CMSIS DMA ring and double-buffer TX | Preserve async progress, no data loss after allocation failure, close safety, buffer-boundary coverage, break/errors, and no VM-blocking waits. |
| Early polling I2C implementation | CMSIS interrupt engine | Preserve allocation-before-I/O, true async cancellation, supported-argument validation, large transfers, clock stretching, and multi-container ownership. |
| Early flat GPIO mapping | SDK-derived pad table and GPIO-owner array | Preserve initial output, destructor cleanup, alternate pads, valid configuration checks, and add the later two-pool/lock requirement. |
| Manually reserved RTC flash | SDK hibernation backup sector | The exact reservation comment is resolved; still test persistence and collision boundaries. |
| Experimental AON/GPIO scripts | Later LDO/pad implementation and regression tests | Do not keep scope archaeology; retain deterministic coverage of the original electrical behavior and deep-sleep ownership issue. |

## Comment ledger

All 377 comments from pending review `4352424414` are accounted for below.
The suffix after each link is the preserved original commit, not GitHub’s
mutable current commit. Path rows can contain a mix of resolved line-level
nits and open general rules; the authoritative current disposition is the
workstream finding above, plus the exceptions below. This compact form is
intentional: the link and original SHA recover the exact context when the
workstream is implemented.

Disposition exceptions:

- **Decision recorded:** r3609289997, r3647488497, r3626188228,
  r3626200014, r3626217943, r3647379232, r3609295035, r3617677392, and
  r3609284626.
- **Discuss:** r3634553044's I2C electrical test matrix still needs
  confirmation. r3516664910 no longer needs a wiring-policy choice, but the
  newly found mismatch between the advertised and compiled SPI1 mappings must
  be fixed before the agreed rewire/test.
- **Resolved behavior:** precise tick rounding, EC618 hardware entropy,
  initial GPIO output level, resource-destructor cleanup, heap UART rings,
  UART-id event routing, contiguous ring copies, async UART TX, SDK-managed
  RTC backup storage, anchor-before-slots, and the anchor rename. These are
  still included in broader regression audits where applicable.
- **Superseded by later evidence:** the assumption that the duplicate GPIO11
  board labels imply two independent chip pads. The multimeter result in
  r3647233513 shows a mirrored board net; alternate-pad support remains
  required for GPIOs that actually have alternate pads.
- **Upstream:** r3609449338’s generic UART library fix belongs on master and
  must be consumed by the rebase rather than carried as an EC618-only change.
- **Deleted/replaced file:** deletion is not a disposition. Comments on the
  retired slot/partition/Python tools are assigned to their replacements in
  “Rewrite follow-through”.

| Reviewed path | Comment(s) and original commit(s) |
| --- | --- |
| `.agent/skills/toit-code/SKILL.md` | [r3516747554](https://github.com/toitlang/toit/pull/3075#discussion_r3516747554)@`bfa0f309` |
| `.github/workflows/ec618-base-release.yml` | [r3609283689](https://github.com/toitlang/toit/pull/3075#discussion_r3609283689)@`ef61213b`, [r3609284626](https://github.com/toitlang/toit/pull/3075#discussion_r3609284626)@`ef61213b`, [r3647488497](https://github.com/toitlang/toit/pull/3075#discussion_r3647488497)@`39ecfcd8` |
| `.gitignore` | [r3359838678](https://github.com/toitlang/toit/pull/3075#discussion_r3359838678)@`bd797293` |
| `Makefile` | [r3606034854](https://github.com/toitlang/toit/pull/3075#discussion_r3606034854)@`0fddb771`, [r3606149488](https://github.com/toitlang/toit/pull/3075#discussion_r3606149488)@`a45e8e4c` |
| `README.ec618.md` | [r3359553001](https://github.com/toitlang/toit/pull/3075#discussion_r3359553001)@`a05e7550`, [r3359554416](https://github.com/toitlang/toit/pull/3075#discussion_r3359554416)@`a05e7550`, [r3647094488](https://github.com/toitlang/toit/pull/3075#discussion_r3647094488)@`56156ccb` |
| `actions/setup-build/action.yml` | [r3647448381](https://github.com/toitlang/toit/pull/3075#discussion_r3647448381)@`0aed688c` |
| `docs/ec618-base-image.md` | [r3609289997](https://github.com/toitlang/toit/pull/3075#discussion_r3609289997)@`ef61213b` |
| `docs/ec618-hw-tests.md` | [r3408794822](https://github.com/toitlang/toit/pull/3075#discussion_r3408794822)@`3dea574c`, [r3408854324](https://github.com/toitlang/toit/pull/3075#discussion_r3408854324)@`1ede2a5e`, [r3410007149](https://github.com/toitlang/toit/pull/3075#discussion_r3410007149)@`da4c461d`, [r3410012426](https://github.com/toitlang/toit/pull/3075#discussion_r3410012426)@`da4c461d`, [r3410024162](https://github.com/toitlang/toit/pull/3075#discussion_r3410024162)@`4e5f7f6a`, [r3410050096](https://github.com/toitlang/toit/pull/3075#discussion_r3410050096)@`8b54345e`, [r3410316281](https://github.com/toitlang/toit/pull/3075#discussion_r3410316281)@`ee28c723`, [r3431479107](https://github.com/toitlang/toit/pull/3075#discussion_r3431479107)@`fc60b91a`, [r3647233513](https://github.com/toitlang/toit/pull/3075#discussion_r3647233513)@`205286c7` |
| `docs/ec618-known-issues.md` | [r3410164134](https://github.com/toitlang/toit/pull/3075#discussion_r3410164134)@`fbf993a5`, [r3591525018](https://github.com/toitlang/toit/pull/3075#discussion_r3591525018)@`1d031986`, [r3591627182](https://github.com/toitlang/toit/pull/3075#discussion_r3591627182)@`0a3ca45f`, [r3604956463](https://github.com/toitlang/toit/pull/3075#discussion_r3604956463)@`784bc399` |
| `docs/ec618-todo.md` | [r3634684124](https://github.com/toitlang/toit/pull/3075#discussion_r3634684124)@`917e30fb`, [r3634685835](https://github.com/toitlang/toit/pull/3075#discussion_r3634685835)@`917e30fb`, [r3647426121](https://github.com/toitlang/toit/pull/3075#discussion_r3647426121)@`f727b762` |
| `docs/ec618-uart-cmsis-rewrite.md` | [r3516723740](https://github.com/toitlang/toit/pull/3075#discussion_r3516723740)@`398fd971`, [r3516731340](https://github.com/toitlang/toit/pull/3075#discussion_r3516731340)@`398fd971`, [r3516738073](https://github.com/toitlang/toit/pull/3075#discussion_r3516738073)@`398fd971` |
| `docs/ota-dual-slot-plan.md` | [r3313982126](https://github.com/toitlang/toit/pull/3075#discussion_r3313982126)@`f8436465`, [r3359701204](https://github.com/toitlang/toit/pull/3075#discussion_r3359701204)@`1efba481` |
| `docs/partition-table-design.md` | [r3647167942](https://github.com/toitlang/toit/pull/3075#discussion_r3647167942)@`392e8f3d` |
| `lib/ec618/ec618.toit` | [r3307234209](https://github.com/toitlang/toit/pull/3075#discussion_r3307234209)@`1f4a6cba`, [r3307242356](https://github.com/toitlang/toit/pull/3075#discussion_r3307242356)@`1f4a6cba`, [r3307246504](https://github.com/toitlang/toit/pull/3075#discussion_r3307246504)@`1f4a6cba`, [r3307247316](https://github.com/toitlang/toit/pull/3075#discussion_r3307247316)@`1f4a6cba`, [r3307254516](https://github.com/toitlang/toit/pull/3075#discussion_r3307254516)@`1f4a6cba`, [r3307265375](https://github.com/toitlang/toit/pull/3075#discussion_r3307265375)@`1f4a6cba`, [r3307299848](https://github.com/toitlang/toit/pull/3075#discussion_r3307299848)@`1f4a6cba`, [r3307312612](https://github.com/toitlang/toit/pull/3075#discussion_r3307312612)@`1f4a6cba`, [r3307313882](https://github.com/toitlang/toit/pull/3075#discussion_r3307313882)@`1f4a6cba`, [r3307316865](https://github.com/toitlang/toit/pull/3075#discussion_r3307316865)@`1f4a6cba`, [r3307330388](https://github.com/toitlang/toit/pull/3075#discussion_r3307330388)@`1f4a6cba`, [r3408340701](https://github.com/toitlang/toit/pull/3075#discussion_r3408340701)@`0c2c4ea5`, [r3516578620](https://github.com/toitlang/toit/pull/3075#discussion_r3516578620)@`f498ee2d`, [r3516593568](https://github.com/toitlang/toit/pull/3075#discussion_r3516593568)@`34705e7f`, [r3516615492](https://github.com/toitlang/toit/pull/3075#discussion_r3516615492)@`514483af`, [r3516655340](https://github.com/toitlang/toit/pull/3075#discussion_r3516655340)@`6dbabf89`, [r3516664910](https://github.com/toitlang/toit/pull/3075#discussion_r3516664910)@`6dbabf89`, [r3604737483](https://github.com/toitlang/toit/pull/3075#discussion_r3604737483)@`784bc399`, [r3604759976](https://github.com/toitlang/toit/pull/3075#discussion_r3604759976)@`784bc399`, [r3604767056](https://github.com/toitlang/toit/pull/3075#discussion_r3604767056)@`784bc399`, [r3626188228](https://github.com/toitlang/toit/pull/3075#discussion_r3626188228)@`76b1d0a2`, [r3647379232](https://github.com/toitlang/toit/pull/3075#discussion_r3647379232)@`e18a4261` |
| `lib/ec618/slot.toit` | [r3359777043](https://github.com/toitlang/toit/pull/3075#discussion_r3359777043)@`9fcb445f`, [r3359782390](https://github.com/toitlang/toit/pull/3075#discussion_r3359782390)@`9fcb445f` |
| `lib/gpio/adc.toit` | [r3409987057](https://github.com/toitlang/toit/pull/3075#discussion_r3409987057)@`cf35b091` |
| `lib/i2c.toit` | [r3516394546](https://github.com/toitlang/toit/pull/3075#discussion_r3516394546)@`a193640e`, [r3516651588](https://github.com/toitlang/toit/pull/3075#discussion_r3516651588)@`80e618f3` |
| `lib/spi.toit` | [r3609335893](https://github.com/toitlang/toit/pull/3075#discussion_r3609335893)@`7b1ef11f`, [r3609349314](https://github.com/toitlang/toit/pull/3075#discussion_r3609349314)@`7b1ef11f` |
| `lib/system/containers.toit` | [r3410193252](https://github.com/toitlang/toit/pull/3075#discussion_r3410193252)@`4e21f6e5` |
| `lib/uart.toit` | [r3307332370](https://github.com/toitlang/toit/pull/3075#discussion_r3307332370)@`1f4a6cba`, [r3307337881](https://github.com/toitlang/toit/pull/3075#discussion_r3307337881)@`1f4a6cba`, [r3609449338](https://github.com/toitlang/toit/pull/3075#discussion_r3609449338)@`e03a61c8` |
| `src/embedded_data.cc` | [r3294904375](https://github.com/toitlang/toit/pull/3075#discussion_r3294904375)@`af6dff58` |
| `src/entropy_mixer.h` | [r3300131800](https://github.com/toitlang/toit/pull/3075#discussion_r3300131800)@`99732fa0` |
| `src/event_sources/uart_ec618.h` | [r3516626970](https://github.com/toitlang/toit/pull/3075#discussion_r3516626970)@`fb6c2616` |
| `src/os.cc` | [r3294420276](https://github.com/toitlang/toit/pull/3075#discussion_r3294420276)@`3477f086`, [r3294422393](https://github.com/toitlang/toit/pull/3075#discussion_r3294422393)@`3477f086` |
| `src/os_ec618.cc` | [r3294874596](https://github.com/toitlang/toit/pull/3075#discussion_r3294874596)@`a2e071cc`, [r3294875760](https://github.com/toitlang/toit/pull/3075#discussion_r3294875760)@`a2e071cc`, [r3294877148](https://github.com/toitlang/toit/pull/3075#discussion_r3294877148)@`a2e071cc`, [r3294878091](https://github.com/toitlang/toit/pull/3075#discussion_r3294878091)@`a2e071cc`, [r3294895296](https://github.com/toitlang/toit/pull/3075#discussion_r3294895296)@`a2e071cc`, [r3295131913](https://github.com/toitlang/toit/pull/3075#discussion_r3295131913)@`a42fc0ca`, [r3295133140](https://github.com/toitlang/toit/pull/3075#discussion_r3295133140)@`a42fc0ca`, [r3300028305](https://github.com/toitlang/toit/pull/3075#discussion_r3300028305)@`1ac9af40`, [r3300036372](https://github.com/toitlang/toit/pull/3075#discussion_r3300036372)@`1ac9af40`, [r3307074407](https://github.com/toitlang/toit/pull/3075#discussion_r3307074407)@`07c1c60a`, [r3625960846](https://github.com/toitlang/toit/pull/3075#discussion_r3625960846)@`5b97ff3e` |
| `src/primitive.h` | [r3298149718](https://github.com/toitlang/toit/pull/3075#discussion_r3298149718)@`f0bb52a2`, [r3298154045](https://github.com/toitlang/toit/pull/3075#discussion_r3298154045)@`f0bb52a2`, [r3298157384](https://github.com/toitlang/toit/pull/3075#discussion_r3298157384)@`f0bb52a2`, [r3298158360](https://github.com/toitlang/toit/pull/3075#discussion_r3298158360)@`f0bb52a2` |
| `src/primitive_core.cc` | [r3294909483](https://github.com/toitlang/toit/pull/3075#discussion_r3294909483)@`af6dff58` |
| `src/primitive_crypto.cc` | [r3605992433](https://github.com/toitlang/toit/pull/3075#discussion_r3605992433)@`b9edded8` |
| `src/primitive_ec618.cc` | [r3300079304](https://github.com/toitlang/toit/pull/3075#discussion_r3300079304)@`5ec68bd5`, [r3313787369](https://github.com/toitlang/toit/pull/3075#discussion_r3313787369)@`84746899`, [r3313795189](https://github.com/toitlang/toit/pull/3075#discussion_r3313795189)@`84746899`, [r3314195875](https://github.com/toitlang/toit/pull/3075#discussion_r3314195875)@`9288ff64`, [r3359789160](https://github.com/toitlang/toit/pull/3075#discussion_r3359789160)@`9fcb445f`, [r3359795068](https://github.com/toitlang/toit/pull/3075#discussion_r3359795068)@`9fcb445f`, [r3359802443](https://github.com/toitlang/toit/pull/3075#discussion_r3359802443)@`9fcb445f`, [r3359806952](https://github.com/toitlang/toit/pull/3075#discussion_r3359806952)@`9fcb445f`, [r3359817759](https://github.com/toitlang/toit/pull/3075#discussion_r3359817759)@`9fcb445f`, [r3359847205](https://github.com/toitlang/toit/pull/3075#discussion_r3359847205)@`f0eb8658`, [r3365975717](https://github.com/toitlang/toit/pull/3075#discussion_r3365975717)@`0620dbc9`, [r3365983941](https://github.com/toitlang/toit/pull/3075#discussion_r3365983941)@`0620dbc9`, [r3369356275](https://github.com/toitlang/toit/pull/3075#discussion_r3369356275)@`03b06737`, [r3369391922](https://github.com/toitlang/toit/pull/3075#discussion_r3369391922)@`06119041`, [r3410165623](https://github.com/toitlang/toit/pull/3075#discussion_r3410165623)@`fbf993a5`, [r3581331896](https://github.com/toitlang/toit/pull/3075#discussion_r3581331896)@`4ce8ab8a`, [r3606211951](https://github.com/toitlang/toit/pull/3075#discussion_r3606211951)@`c29d11da` |
| `src/primitive_file_non_win.cc` | [r3294991130](https://github.com/toitlang/toit/pull/3075#discussion_r3294991130)@`af6dff58` |
| `src/program_memory.h` | [r3300134585](https://github.com/toitlang/toit/pull/3075#discussion_r3300134585)@`99732fa0` |
| `src/resources/adc_ec618.cc` | [r3408801559](https://github.com/toitlang/toit/pull/3075#discussion_r3408801559)@`2e6c6810`, [r3431434774](https://github.com/toitlang/toit/pull/3075#discussion_r3431434774)@`32b2489f` |
| `src/resources/cellular_ec618.cc` | [r3299942059](https://github.com/toitlang/toit/pull/3075#discussion_r3299942059)@`401b43ea` |
| `src/resources/gpio_ec618.cc` | [r3299727466](https://github.com/toitlang/toit/pull/3075#discussion_r3299727466)@`9466fcd3`, [r3299732550](https://github.com/toitlang/toit/pull/3075#discussion_r3299732550)@`9466fcd3`, [r3299889375](https://github.com/toitlang/toit/pull/3075#discussion_r3299889375)@`d93d427a`, [r3299892126](https://github.com/toitlang/toit/pull/3075#discussion_r3299892126)@`d93d427a`, [r3299902303](https://github.com/toitlang/toit/pull/3075#discussion_r3299902303)@`d93d427a`, [r3409996096](https://github.com/toitlang/toit/pull/3075#discussion_r3409996096)@`271b21b5`, [r3431249175](https://github.com/toitlang/toit/pull/3075#discussion_r3431249175)@`9aee6a10`, [r3516681520](https://github.com/toitlang/toit/pull/3075#discussion_r3516681520)@`6dd16467`, [r3646988710](https://github.com/toitlang/toit/pull/3075#discussion_r3646988710)@`06f6037e`, [r3647004470](https://github.com/toitlang/toit/pull/3075#discussion_r3647004470)@`06f6037e` |
| `src/resources/i2c_ec618.cc` | [r3299755148](https://github.com/toitlang/toit/pull/3075#discussion_r3299755148)@`9466fcd3`, [r3299759138](https://github.com/toitlang/toit/pull/3075#discussion_r3299759138)@`9466fcd3`, [r3299771000](https://github.com/toitlang/toit/pull/3075#discussion_r3299771000)@`9466fcd3`, [r3299775336](https://github.com/toitlang/toit/pull/3075#discussion_r3299775336)@`9466fcd3`, [r3299784072](https://github.com/toitlang/toit/pull/3075#discussion_r3299784072)@`9466fcd3`, [r3299793064](https://github.com/toitlang/toit/pull/3075#discussion_r3299793064)@`9466fcd3`, [r3299803371](https://github.com/toitlang/toit/pull/3075#discussion_r3299803371)@`9466fcd3`, [r3299808912](https://github.com/toitlang/toit/pull/3075#discussion_r3299808912)@`9466fcd3`, [r3299810935](https://github.com/toitlang/toit/pull/3075#discussion_r3299810935)@`9466fcd3`, [r3299815403](https://github.com/toitlang/toit/pull/3075#discussion_r3299815403)@`9466fcd3`, [r3431571601](https://github.com/toitlang/toit/pull/3075#discussion_r3431571601)@`e31a1b03`, [r3516409699](https://github.com/toitlang/toit/pull/3075#discussion_r3516409699)@`a193640e`, [r3516416422](https://github.com/toitlang/toit/pull/3075#discussion_r3516416422)@`a193640e`, [r3516421430](https://github.com/toitlang/toit/pull/3075#discussion_r3516421430)@`a193640e`, [r3516423462](https://github.com/toitlang/toit/pull/3075#discussion_r3516423462)@`a193640e`, [r3516437270](https://github.com/toitlang/toit/pull/3075#discussion_r3516437270)@`a193640e`, [r3516452160](https://github.com/toitlang/toit/pull/3075#discussion_r3516452160)@`a193640e`, [r3516455893](https://github.com/toitlang/toit/pull/3075#discussion_r3516455893)@`a193640e`, [r3516463216](https://github.com/toitlang/toit/pull/3075#discussion_r3516463216)@`a193640e`, [r3516468676](https://github.com/toitlang/toit/pull/3075#discussion_r3516468676)@`a193640e`, [r3599343551](https://github.com/toitlang/toit/pull/3075#discussion_r3599343551)@`e163753b`, [r3599359668](https://github.com/toitlang/toit/pull/3075#discussion_r3599359668)@`e163753b`, [r3599381166](https://github.com/toitlang/toit/pull/3075#discussion_r3599381166)@`e163753b`, [r3599401255](https://github.com/toitlang/toit/pull/3075#discussion_r3599401255)@`e163753b`, [r3599406005](https://github.com/toitlang/toit/pull/3075#discussion_r3599406005)@`e163753b`, [r3599442057](https://github.com/toitlang/toit/pull/3075#discussion_r3599442057)@`e163753b`, [r3599443422](https://github.com/toitlang/toit/pull/3075#discussion_r3599443422)@`e163753b`, [r3599443928](https://github.com/toitlang/toit/pull/3075#discussion_r3599443928)@`e163753b`, [r3599462739](https://github.com/toitlang/toit/pull/3075#discussion_r3599462739)@`e163753b`, [r3599508405](https://github.com/toitlang/toit/pull/3075#discussion_r3599508405)@`eb96382c`, [r3599518153](https://github.com/toitlang/toit/pull/3075#discussion_r3599518153)@`eb96382c`, [r3634309376](https://github.com/toitlang/toit/pull/3075#discussion_r3634309376)@`308ee13f`, [r3634451106](https://github.com/toitlang/toit/pull/3075#discussion_r3634451106)@`308ee13f`, [r3634572784](https://github.com/toitlang/toit/pull/3075#discussion_r3634572784)@`818097b3` |
| `src/resources/pad_table_ec618.cc` | [r3516596051](https://github.com/toitlang/toit/pull/3075#discussion_r3516596051)@`34705e7f`, [r3647026946](https://github.com/toitlang/toit/pull/3075#discussion_r3647026946)@`06f6037e` |
| `src/resources/pwm_ec618.cc` | [r3410468338](https://github.com/toitlang/toit/pull/3075#discussion_r3410468338)@`c29420df`, [r3410476752](https://github.com/toitlang/toit/pull/3075#discussion_r3410476752)@`c29420df`, [r3410482711](https://github.com/toitlang/toit/pull/3075#discussion_r3410482711)@`c29420df`, [r3410488472](https://github.com/toitlang/toit/pull/3075#discussion_r3410488472)@`c29420df` |
| `src/resources/spi_ec618.cc` | [r3516504729](https://github.com/toitlang/toit/pull/3075#discussion_r3516504729)@`58296e67`, [r3516506527](https://github.com/toitlang/toit/pull/3075#discussion_r3516506527)@`58296e67`, [r3516525277](https://github.com/toitlang/toit/pull/3075#discussion_r3516525277)@`58296e67`, [r3516539748](https://github.com/toitlang/toit/pull/3075#discussion_r3516539748)@`58296e67`, [r3516543491](https://github.com/toitlang/toit/pull/3075#discussion_r3516543491)@`58296e67`, [r3516558613](https://github.com/toitlang/toit/pull/3075#discussion_r3516558613)@`58296e67`, [r3609344889](https://github.com/toitlang/toit/pull/3075#discussion_r3609344889)@`7b1ef11f`, [r3609352272](https://github.com/toitlang/toit/pull/3075#discussion_r3609352272)@`7b1ef11f`, [r3609362318](https://github.com/toitlang/toit/pull/3075#discussion_r3609362318)@`7b1ef11f` |
| `src/resources/tcp_esp32.cc` | [r3300058616](https://github.com/toitlang/toit/pull/3075#discussion_r3300058616)@`252e2f09` |
| `src/resources/uart_ec618.cc` | [r3299822697](https://github.com/toitlang/toit/pull/3075#discussion_r3299822697)@`9466fcd3`, [r3299848395](https://github.com/toitlang/toit/pull/3075#discussion_r3299848395)@`9466fcd3`, [r3299850699](https://github.com/toitlang/toit/pull/3075#discussion_r3299850699)@`9466fcd3`, [r3307448950](https://github.com/toitlang/toit/pull/3075#discussion_r3307448950)@`1f4a6cba`, [r3307452304](https://github.com/toitlang/toit/pull/3075#discussion_r3307452304)@`1f4a6cba`, [r3307457048](https://github.com/toitlang/toit/pull/3075#discussion_r3307457048)@`1f4a6cba`, [r3307468676](https://github.com/toitlang/toit/pull/3075#discussion_r3307468676)@`1f4a6cba`, [r3307477930](https://github.com/toitlang/toit/pull/3075#discussion_r3307477930)@`1f4a6cba`, [r3314088436](https://github.com/toitlang/toit/pull/3075#discussion_r3314088436)@`ed48033c`, [r3410419689](https://github.com/toitlang/toit/pull/3075#discussion_r3410419689)@`6d8a190e`, [r3410435780](https://github.com/toitlang/toit/pull/3075#discussion_r3410435780)@`6d8a190e`, [r3410447752](https://github.com/toitlang/toit/pull/3075#discussion_r3410447752)@`9fc21853`, [r3516766763](https://github.com/toitlang/toit/pull/3075#discussion_r3516766763)@`bfa0f309`, [r3516772040](https://github.com/toitlang/toit/pull/3075#discussion_r3516772040)@`bfa0f309`, [r3516776321](https://github.com/toitlang/toit/pull/3075#discussion_r3516776321)@`bfa0f309`, [r3516776950](https://github.com/toitlang/toit/pull/3075#discussion_r3516776950)@`bfa0f309`, [r3516781219](https://github.com/toitlang/toit/pull/3075#discussion_r3516781219)@`bfa0f309`, [r3516787929](https://github.com/toitlang/toit/pull/3075#discussion_r3516787929)@`bfa0f309`, [r3516790829](https://github.com/toitlang/toit/pull/3075#discussion_r3516790829)@`bfa0f309`, [r3516798015](https://github.com/toitlang/toit/pull/3075#discussion_r3516798015)@`bfa0f309`, [r3516804933](https://github.com/toitlang/toit/pull/3075#discussion_r3516804933)@`bfa0f309`, [r3516806155](https://github.com/toitlang/toit/pull/3075#discussion_r3516806155)@`bfa0f309`, [r3516814575](https://github.com/toitlang/toit/pull/3075#discussion_r3516814575)@`d51319ca`, [r3581323754](https://github.com/toitlang/toit/pull/3075#discussion_r3581323754)@`4ce8ab8a`, [r3581516402](https://github.com/toitlang/toit/pull/3075#discussion_r3581516402)@`e5efbcd3`, [r3590939696](https://github.com/toitlang/toit/pull/3075#discussion_r3590939696)@`b206bb45`, [r3590997823](https://github.com/toitlang/toit/pull/3075#discussion_r3590997823)@`2ab5c8e7`, [r3591070788](https://github.com/toitlang/toit/pull/3075#discussion_r3591070788)@`2ab5c8e7`, [r3591310574](https://github.com/toitlang/toit/pull/3075#discussion_r3591310574)@`634ea37f`, [r3591337815](https://github.com/toitlang/toit/pull/3075#discussion_r3591337815)@`634ea37f`, [r3609464423](https://github.com/toitlang/toit/pull/3075#discussion_r3609464423)@`d9cc6603`, [r3609472070](https://github.com/toitlang/toit/pull/3075#discussion_r3609472070)@`d9cc6603`, [r3609474551](https://github.com/toitlang/toit/pull/3075#discussion_r3609474551)@`d9cc6603`, [r3609479126](https://github.com/toitlang/toit/pull/3075#discussion_r3609479126)@`d9cc6603` |
| `src/resources/x509.h` | [r3300017734](https://github.com/toitlang/toit/pull/3075#discussion_r3300017734)@`8b04a0d3` |
| `src/rtc_memory_ec618.cc` | [r3307211959](https://github.com/toitlang/toit/pull/3075#discussion_r3307211959)@`aa79e221` |
| `src/slot_reloc_ec618.cc` | [r3365855001](https://github.com/toitlang/toit/pull/3075#discussion_r3365855001)@`b003bea8`, [r3365860672](https://github.com/toitlang/toit/pull/3075#discussion_r3365860672)@`b003bea8`, [r3365862130](https://github.com/toitlang/toit/pull/3075#discussion_r3365862130)@`b003bea8`, [r3366005111](https://github.com/toitlang/toit/pull/3075#discussion_r3366005111)@`18302568`, [r3369361118](https://github.com/toitlang/toit/pull/3075#discussion_r3369361118)@`03b06737`, [r3369367478](https://github.com/toitlang/toit/pull/3075#discussion_r3369367478)@`03b06737` |
| `src/slot_reloc_ec618.h` | [r3365908894](https://github.com/toitlang/toit/pull/3075#discussion_r3365908894)@`b003bea8`, [r3369379760](https://github.com/toitlang/toit/pull/3075#discussion_r3369379760)@`03b06737` |
| `src/tags.h` | [r3298161762](https://github.com/toitlang/toit/pull/3075#discussion_r3298161762)@`f0bb52a2`, [r3298162878](https://github.com/toitlang/toit/pull/3075#discussion_r3298162878)@`f0bb52a2` |
| `src/third_party/mbedtls_ec618/threading_alt.h` | [r3294396799](https://github.com/toitlang/toit/pull/3075#discussion_r3294396799)@`e9bbdf49` |
| `src/toit_ec618.cc` | [r3295111642](https://github.com/toitlang/toit/pull/3075#discussion_r3295111642)@`af6dff58`, [r3307097234](https://github.com/toitlang/toit/pull/3075#discussion_r3307097234)@`07c1c60a`, [r3313879352](https://github.com/toitlang/toit/pull/3075#discussion_r3313879352)@`84746899`, [r3313897864](https://github.com/toitlang/toit/pull/3075#discussion_r3313897864)@`84746899`, [r3369656895](https://github.com/toitlang/toit/pull/3075#discussion_r3369656895)@`dbf1cbd2`, [r3410021687](https://github.com/toitlang/toit/pull/3075#discussion_r3410021687)@`78074ece`, [r3604843793](https://github.com/toitlang/toit/pull/3075#discussion_r3604843793)@`784bc399`, [r3604907003](https://github.com/toitlang/toit/pull/3075#discussion_r3604907003)@`784bc399`, [r3604935536](https://github.com/toitlang/toit/pull/3075#discussion_r3604935536)@`784bc399` |
| `system/extensions/ec618/firmware.toit` | [r3369627999](https://github.com/toitlang/toit/pull/3075#discussion_r3369627999)@`06119041` |
| `system/extensions/ec618/storage.toit` | [r3300165007](https://github.com/toitlang/toit/pull/3075#discussion_r3300165007)@`da090bcb` |
| `tests/hw/ec618/README.md` | [r3408786781](https://github.com/toitlang/toit/pull/3075#discussion_r3408786781)@`7a3708df`, [r3408787715](https://github.com/toitlang/toit/pull/3075#discussion_r3408787715)@`7a3708df`, [r3516600676](https://github.com/toitlang/toit/pull/3075#discussion_r3516600676)@`b5175bf6`, [r3516687069](https://github.com/toitlang/toit/pull/3075#discussion_r3516687069)@`6dd16467` |
| `tests/hw/ec618/adc-ec618.toit` | [r3408809430](https://github.com/toitlang/toit/pull/3075#discussion_r3408809430)@`2e6c6810`, [r3408811756](https://github.com/toitlang/toit/pull/3075#discussion_r3408811756)@`2e6c6810` |
| `tests/hw/ec618/aon-wu-output-experiments-ec618.toit` | [r3609436328](https://github.com/toitlang/toit/pull/3075#discussion_r3609436328)@`44a8743c` |
| `tests/hw/ec618/aon-wu-output-repro-ec618.toit` | [r3516682487](https://github.com/toitlang/toit/pull/3075#discussion_r3516682487)@`6dd16467` |
| `tests/hw/ec618/aon-wu-scope-ec618.toit` | [r3609445333](https://github.com/toitlang/toit/pull/3075#discussion_r3609445333)@`296d9a9e` |
| `tests/hw/ec618/gpio-alt-ec618.toit` | [r3647047861](https://github.com/toitlang/toit/pull/3075#discussion_r3647047861)@`06f6037e` |
| `tests/hw/ec618/gpio-aon-input-ec618.toit` | [r3609396947](https://github.com/toitlang/toit/pull/3075#discussion_r3609396947)@`b14c3054` |
| `tests/hw/ec618/gpio-input-ec618.toit` | [r3410076642](https://github.com/toitlang/toit/pull/3075#discussion_r3410076642)@`ccd0a8c0`, [r3625816192](https://github.com/toitlang/toit/pull/3075#discussion_r3625816192)@`5f6fa0a7` |
| `tests/hw/ec618/gpio-interrupt-esp32.toit` | [r3599256474](https://github.com/toitlang/toit/pull/3075#discussion_r3599256474)@`f714e42d` |
| `tests/hw/ec618/gpio-map-ec618.toit` | [r3410024581](https://github.com/toitlang/toit/pull/3075#discussion_r3410024581)@`4e5f7f6a`, [r3410025087](https://github.com/toitlang/toit/pull/3075#discussion_r3410025087)@`4e5f7f6a`, [r3410026869](https://github.com/toitlang/toit/pull/3075#discussion_r3410026869)@`4e5f7f6a`, [r3431489032](https://github.com/toitlang/toit/pull/3075#discussion_r3431489032)@`fc60b91a` |
| `tests/hw/ec618/gpio-map-esp32.toit` | [r3410027275](https://github.com/toitlang/toit/pull/3075#discussion_r3410027275)@`4e5f7f6a`, [r3410027781](https://github.com/toitlang/toit/pull/3075#discussion_r3410027781)@`4e5f7f6a` |
| `tests/hw/ec618/gpio-multi-ec618.toit` | [r3625852161](https://github.com/toitlang/toit/pull/3075#discussion_r3625852161)@`f684a7f8` |
| `tests/hw/ec618/gpio-output-ec618.toit` | [r3408783298](https://github.com/toitlang/toit/pull/3075#discussion_r3408783298)@`7a3708df`, [r3408783827](https://github.com/toitlang/toit/pull/3075#discussion_r3408783827)@`7a3708df`, [r3647283960](https://github.com/toitlang/toit/pull/3075#discussion_r3647283960)@`205286c7` |
| `tests/hw/ec618/gpio-pull-ec618.toit` | [r3410008689](https://github.com/toitlang/toit/pull/3075#discussion_r3410008689)@`da4c461d`, [r3410009956](https://github.com/toitlang/toit/pull/3075#discussion_r3410009956)@`da4c461d`, [r3410010804](https://github.com/toitlang/toit/pull/3075#discussion_r3410010804)@`da4c461d`, [r3410019305](https://github.com/toitlang/toit/pull/3075#discussion_r3410019305)@`da4c461d` |
| `tests/hw/ec618/gpio-pull-esp32.toit` | [r3410015456](https://github.com/toitlang/toit/pull/3075#discussion_r3410015456)@`da4c461d`, [r3410015883](https://github.com/toitlang/toit/pull/3075#discussion_r3410015883)@`da4c461d`, [r3410016856](https://github.com/toitlang/toit/pull/3075#discussion_r3410016856)@`da4c461d` |
| `tests/hw/ec618/gpio-vlevel-ec618.toit` | [r3410051190](https://github.com/toitlang/toit/pull/3075#discussion_r3410051190)@`8b54345e` |
| `tests/hw/ec618/gpio-vlevel-esp32.toit` | [r3410052283](https://github.com/toitlang/toit/pull/3075#discussion_r3410052283)@`8b54345e` |
| `tests/hw/ec618/gpio22-probe-esp32.toit` | [r3604967805](https://github.com/toitlang/toit/pull/3075#discussion_r3604967805)@`784bc399` |
| `tests/hw/ec618/i2c-speed-ec618.toit` | [r3634553044](https://github.com/toitlang/toit/pull/3075#discussion_r3634553044)@`308ee13f` |
| `tests/hw/ec618/i2c-stretch-ec618.toit` | [r3599526192](https://github.com/toitlang/toit/pull/3075#discussion_r3599526192)@`eb96382c` |
| `tests/hw/ec618/i2c-torture-ec618.toit` | [r3599475156](https://github.com/toitlang/toit/pull/3075#discussion_r3599475156)@`e163753b` |
| `tests/hw/ec618/i2c0-wire-esp32.toit` | [r3609404057](https://github.com/toitlang/toit/pull/3075#discussion_r3609404057)@`f0f945ed` |
| `tests/hw/ec618/pad26-scope-ec618.toit` | [r3626242128](https://github.com/toitlang/toit/pull/3075#discussion_r3626242128)@`369c345f` |
| `tests/hw/ec618/pwm-aon-ec618.toit` | [r3609439010](https://github.com/toitlang/toit/pull/3075#discussion_r3609439010)@`44a8743c` |
| `tests/hw/ec618/pwm-esp32.toit` | [r3410511547](https://github.com/toitlang/toit/pull/3075#discussion_r3410511547)@`c29420df`, [r3410512407](https://github.com/toitlang/toit/pull/3075#discussion_r3410512407)@`c29420df` |
| `tests/hw/ec618/rc522-ec618.toit` | [r3516565272](https://github.com/toitlang/toit/pull/3075#discussion_r3516565272)@`58296e67` |
| `tests/hw/ec618/rc522-probe-esp32.toit` | [r3516571120](https://github.com/toitlang/toit/pull/3075#discussion_r3516571120)@`58296e67` |
| `tests/hw/ec618/uart-contract-test.toit` | [r3314096627](https://github.com/toitlang/toit/pull/3075#discussion_r3314096627)@`b43adaeb`, [r3647083519](https://github.com/toitlang/toit/pull/3075#discussion_r3647083519)@`06f6037e`, [r3647305891](https://github.com/toitlang/toit/pull/3075#discussion_r3647305891)@`205286c7` |
| `tests/hw/ec618/uart2-bigdata-ec618.toit` | [r3410326897](https://github.com/toitlang/toit/pull/3075#discussion_r3410326897)@`ee28c723`, [r3410337012](https://github.com/toitlang/toit/pull/3075#discussion_r3410337012)@`ee28c723`, [r3410337877](https://github.com/toitlang/toit/pull/3075#discussion_r3410337877)@`ee28c723` |
| `tests/hw/ec618/uart2-bigdata-esp32.toit` | [r3410344854](https://github.com/toitlang/toit/pull/3075#discussion_r3410344854)@`ee28c723`, [r3410349541](https://github.com/toitlang/toit/pull/3075#discussion_r3410349541)@`ee28c723` |
| `tests/hw/ec618/uart2-duplex-ec618.toit` | [r3410399733](https://github.com/toitlang/toit/pull/3075#discussion_r3410399733)@`710e2ffc`, [r3591105175](https://github.com/toitlang/toit/pull/3075#discussion_r3591105175)@`2ab5c8e7` |
| `tests/hw/ec618/uart2-echo-ec618.toit` | [r3410111050](https://github.com/toitlang/toit/pull/3075#discussion_r3410111050)@`e8fc3c1b`, [r3410111833](https://github.com/toitlang/toit/pull/3075#discussion_r3410111833)@`e8fc3c1b`, [r3410113539](https://github.com/toitlang/toit/pull/3075#discussion_r3410113539)@`e8fc3c1b`, [r3410122670](https://github.com/toitlang/toit/pull/3075#discussion_r3410122670)@`e8fc3c1b` |
| `tests/hw/ec618/uart2-echo-esp32.toit` | [r3410139755](https://github.com/toitlang/toit/pull/3075#discussion_r3410139755)@`e8fc3c1b` |
| `tests/hw/ec618/uart2-ring-ec618.toit` | [r3410357680](https://github.com/toitlang/toit/pull/3075#discussion_r3410357680)@`ee28c723`, [r3590959543](https://github.com/toitlang/toit/pull/3075#discussion_r3590959543)@`4b5d59be` |
| `tests/hw/ec618/wakeup-gpio22-ec618.toit` | [r3604971816](https://github.com/toitlang/toit/pull/3075#discussion_r3604971816)@`784bc399`, [r3604976206](https://github.com/toitlang/toit/pull/3075#discussion_r3604976206)@`784bc399`, [r3604979313](https://github.com/toitlang/toit/pull/3075#discussion_r3604979313)@`784bc399` |
| `tests/hw/ec618/wakeup-gpio22-esp32.toit` | [r3604992052](https://github.com/toitlang/toit/pull/3075#discussion_r3604992052)@`784bc399` |
| `tests/hw/esp-tester/dual-bridge-esp32.toit` | [r3626266289](https://github.com/toitlang/toit/pull/3075#discussion_r3626266289)@`0c3840ff` |
| `tests/hw/esp-tester/mini-jag.toit` | [r3408350313](https://github.com/toitlang/toit/pull/3075#discussion_r3408350313)@`81fd6729`, [r3646712661](https://github.com/toitlang/toit/pull/3075#discussion_r3646712661)@`98cc9368`, [r3646723345](https://github.com/toitlang/toit/pull/3075#discussion_r3646723345)@`98cc9368` |
| `tests/hw/esp-tester/sleeper.toit` | [r3410042416](https://github.com/toitlang/toit/pull/3075#discussion_r3410042416)@`e2d69499` |
| `tests/hw/esp-tester/tester.toit` | [r3463581098](https://github.com/toitlang/toit/pull/3075#discussion_r3463581098)@`52ff1823`, [r3516704077](https://github.com/toitlang/toit/pull/3075#discussion_r3516704077)@`c5ced05a`, [r3581336511](https://github.com/toitlang/toit/pull/3075#discussion_r3581336511)@`4ce8ab8a`, [r3591426404](https://github.com/toitlang/toit/pull/3075#discussion_r3591426404)@`634ea37f` |
| `tests/hw/esp-tester/uart-bridge-esp32.toit` | [r3591441178](https://github.com/toitlang/toit/pull/3075#discussion_r3591441178)@`634ea37f` |
| `third_party/mbedtls_config_toit.h` | [r3294399940](https://github.com/toitlang/toit/pull/3075#discussion_r3294399940)@`e9bbdf49`, [r3294401099](https://github.com/toitlang/toit/pull/3075#discussion_r3294401099)@`e9bbdf49` |
| `toolchains/ec618.cmake` | [r3294395236](https://github.com/toitlang/toit/pull/3075#discussion_r3294395236)@`930521ba` |
| `toolchains/ec618/ec618_config.h` | [r3314112740](https://github.com/toitlang/toit/pull/3075#discussion_r3314112740)@`b43adaeb`, [r3626212687](https://github.com/toitlang/toit/pull/3075#discussion_r3626212687)@`76b1d0a2` |
| `toolchains/ec618/partitions.yaml` | [r3609511155](https://github.com/toitlang/toit/pull/3075#discussion_r3609511155)@`20627af8`, [r3617677392](https://github.com/toitlang/toit/pull/3075#discussion_r3617677392)@`3ab4d5b4` |
| `toolchains/ec618/project/README.md` | [r3463572127](https://github.com/toitlang/toit/pull/3075#discussion_r3463572127)@`942d7471`, [r3463573753](https://github.com/toitlang/toit/pull/3075#discussion_r3463573753)@`942d7471` |
| `toolchains/ec618/project/inc/RTE_Device.h` | [r3463294291](https://github.com/toitlang/toit/pull/3075#discussion_r3463294291)@`aa9c041e`, [r3591183827](https://github.com/toitlang/toit/pull/3075#discussion_r3591183827)@`2ab5c8e7`, [r3591186391](https://github.com/toitlang/toit/pull/3075#discussion_r3591186391)@`2ab5c8e7`, [r3591581837](https://github.com/toitlang/toit/pull/3075#discussion_r3591581837)@`1d031986` |
| `toolchains/ec618/project/inc/slot_marker.h` | [r3463299696](https://github.com/toitlang/toit/pull/3075#discussion_r3463299696)@`aa9c041e` |
| `toolchains/ec618/project/src/anchor.c` | [r3615294068](https://github.com/toitlang/toit/pull/3075#discussion_r3615294068)@`69d10451`, [r3626200014](https://github.com/toitlang/toit/pull/3075#discussion_r3626200014)@`76b1d0a2` |
| `toolchains/ec618/project/src/bsp_custom.c` | [r3463348231](https://github.com/toitlang/toit/pull/3075#discussion_r3463348231)@`aa9c041e`, [r3463356647](https://github.com/toitlang/toit/pull/3075#discussion_r3463356647)@`aa9c041e`, [r3463365802](https://github.com/toitlang/toit/pull/3075#discussion_r3463365802)@`aa9c041e` |
| `toolchains/ec618/project/src/cmpctmalloc/cmpctmalloc.c` | [r3516720275](https://github.com/toitlang/toit/pull/3075#discussion_r3516720275)@`6d04fd57` |
| `toolchains/ec618/project/src/plat_keep.c` | [r3605767018](https://github.com/toitlang/toit/pull/3075#discussion_r3605767018)@`560cd022` |
| `toolchains/ec618/project/src/sys_ro_override.c` | [r3463499838](https://github.com/toitlang/toit/pull/3075#discussion_r3463499838)@`aa9c041e` |
| `toolchains/ec618/project/src/toit_main.c` | [r3463521127](https://github.com/toitlang/toit/pull/3075#discussion_r3463521127)@`aa9c041e`, [r3463560993](https://github.com/toitlang/toit/pull/3075#discussion_r3463560993)@`aa9c041e` |
| `tools/ec618/build-dual-image.toit` | [r3366173437](https://github.com/toitlang/toit/pull/3075#discussion_r3366173437)@`dc90d64f`, [r3366191257](https://github.com/toitlang/toit/pull/3075#discussion_r3366191257)@`dc90d64f`, [r3366196020](https://github.com/toitlang/toit/pull/3075#discussion_r3366196020)@`dc90d64f`, [r3366237475](https://github.com/toitlang/toit/pull/3075#discussion_r3366237475)@`011e0e8a`, [r3366239942](https://github.com/toitlang/toit/pull/3075#discussion_r3366239942)@`011e0e8a`, [r3369289785](https://github.com/toitlang/toit/pull/3075#discussion_r3369289785)@`cdcd0b7d` |
| `tools/ec618/check-slot-pic.toit` | [r3362409313](https://github.com/toitlang/toit/pull/3075#discussion_r3362409313)@`382810af`, [r3362423769](https://github.com/toitlang/toit/pull/3075#discussion_r3362423769)@`382810af`, [r3362426355](https://github.com/toitlang/toit/pull/3075#discussion_r3362426355)@`382810af`, [r3362427930](https://github.com/toitlang/toit/pull/3075#discussion_r3362427930)@`382810af` |
| `tools/ec618/check-slot-refs.toit` | [r3408151012](https://github.com/toitlang/toit/pull/3075#discussion_r3408151012)@`1095e59a` |
| `tools/ec618/gen-anchor.toit` | [r3617690848](https://github.com/toitlang/toit/pull/3075#discussion_r3617690848)@`3ab4d5b4`, [r3617713565](https://github.com/toitlang/toit/pull/3075#discussion_r3617713565)@`3ab4d5b4` |
| `tools/ec618/gen-base-id.toit` | [r3609295035](https://github.com/toitlang/toit/pull/3075#discussion_r3609295035)@`ef61213b`, [r3609304250](https://github.com/toitlang/toit/pull/3075#discussion_r3609304250)@`ef61213b`, [r3609308298](https://github.com/toitlang/toit/pull/3075#discussion_r3609308298)@`ef61213b` |
| `tools/ec618/gen-partitions.toit` | [r3609502637](https://github.com/toitlang/toit/pull/3075#discussion_r3609502637)@`73e84a7a`, [r3609504782](https://github.com/toitlang/toit/pull/3075#discussion_r3609504782)@`73e84a7a` |
| `tools/ec618/gen-plat-jt.toit` | [r3362449699](https://github.com/toitlang/toit/pull/3075#discussion_r3362449699)@`382810af`, [r3362456885](https://github.com/toitlang/toit/pull/3075#discussion_r3362456885)@`382810af`, [r3362484342](https://github.com/toitlang/toit/pull/3075#discussion_r3362484342)@`382810af`, [r3408317714](https://github.com/toitlang/toit/pull/3075#discussion_r3408317714)@`c25055bf`, [r3408319256](https://github.com/toitlang/toit/pull/3075#discussion_r3408319256)@`c25055bf`, [r3408321051](https://github.com/toitlang/toit/pull/3075#discussion_r3408321051)@`c25055bf` |
| `tools/ec618/gen-slot-ld.toit` | [r3606080071](https://github.com/toitlang/toit/pull/3075#discussion_r3606080071)@`a45e8e4c` |
| `tools/ec618/gen-slot-reloc.toit` | [r3365782383](https://github.com/toitlang/toit/pull/3075#discussion_r3365782383)@`80f49388`, [r3365789325](https://github.com/toitlang/toit/pull/3075#discussion_r3365789325)@`80f49388`, [r3365790406](https://github.com/toitlang/toit/pull/3075#discussion_r3365790406)@`80f49388`, [r3365806871](https://github.com/toitlang/toit/pull/3075#discussion_r3365806871)@`80f49388`, [r3365822407](https://github.com/toitlang/toit/pull/3075#discussion_r3365822407)@`80f49388`, [r3365844463](https://github.com/toitlang/toit/pull/3075#discussion_r3365844463)@`80f49388`, [r3408835934](https://github.com/toitlang/toit/pull/3075#discussion_r3408835934)@`566664a0`, [r3408836205](https://github.com/toitlang/toit/pull/3075#discussion_r3408836205)@`566664a0` |
| `tools/ec618/provision.toit` | [r3625885763](https://github.com/toitlang/toit/pull/3075#discussion_r3625885763)@`5458e12b`, [r3626217943](https://github.com/toitlang/toit/pull/3075#discussion_r3626217943)@`76b1d0a2` |
| `tools/ec618/splice-slot.toit` | [r3606140830](https://github.com/toitlang/toit/pull/3075#discussion_r3606140830)@`a45e8e4c`, [r3606146797](https://github.com/toitlang/toit/pull/3075#discussion_r3606146797)@`a45e8e4c`, [r3617724176](https://github.com/toitlang/toit/pull/3075#discussion_r3617724176)@`3ab4d5b4` |
| `tools/firmware.toit` | [r3300182439](https://github.com/toitlang/toit/pull/3075#discussion_r3300182439)@`753cf3a7`, [r3300189944](https://github.com/toitlang/toit/pull/3075#discussion_r3300189944)@`753cf3a7`, [r3300191965](https://github.com/toitlang/toit/pull/3075#discussion_r3300191965)@`753cf3a7`, [r3300197337](https://github.com/toitlang/toit/pull/3075#discussion_r3300197337)@`753cf3a7`, [r3300200539](https://github.com/toitlang/toit/pull/3075#discussion_r3300200539)@`753cf3a7`, [r3300205665](https://github.com/toitlang/toit/pull/3075#discussion_r3300205665)@`99426d1f`, [r3369316204](https://github.com/toitlang/toit/pull/3075#discussion_r3369316204)@`cdcd0b7d`, [r3369320946](https://github.com/toitlang/toit/pull/3075#discussion_r3369320946)@`cdcd0b7d`, [r3410169818](https://github.com/toitlang/toit/pull/3075#discussion_r3410169818)@`d2b761d3`, [r3617739328](https://github.com/toitlang/toit/pull/3075#discussion_r3617739328)@`ef67109c` |
| `tools/gen_plat_jt.py` | [r3359479063](https://github.com/toitlang/toit/pull/3075#discussion_r3359479063)@`154efeca` |
