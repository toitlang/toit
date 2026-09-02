# PR #3075 review tracker

This document tracks Florian's pending review comments on
[toitlang/toit#3075](https://github.com/toitlang/toit/pull/3075). It is based
on each comment's preserved `original_commit_id`, not GitHub's mutable current
`commit_id`.

Review baseline: authenticated GitHub snapshot and local/remote
`floitsch/ec618` at `3babe6e8` (2026-07-27). Later worktree results are called
out explicitly; they are not part of that committed baseline.

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
- **Explanation** — the reviewed behavior is intentional; the response should
  supply missing context rather than claim a source fix.
- **Rebase** — the requested final shape depends on post-branch common APIs and
  must be completed while rebasing, not papered over on the old API.

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

## Unpublished second-round review (2026-08-18 through 2026-09-01)

This is a separate review round from the submitted comments summarized below.
The authenticated snapshot contains one pending review
(`PRR_kwDOGXd5Hs8AAAABJ9Mxtg`) with **50 unpublished root comments**, all by
Florian. All 50 belong to this round and must be answered. The pending review
is attached to `c05614aa`, but each comment's `original_commit_id` is used
below to recover the code that was actually reviewed. Comments 48–50 were
added after the first fix series was pushed at `95f5419c`.

The entries are numbered by GitHub creation time. This matters because the
comments were written one at a time over several weeks: a later comment can
review or correct a commit that was itself written in response to an earlier
comment. “Resolved later” below therefore means a later branch commit already
addresses this *new* comment; it does not refer to the submitted first round.

The authenticated review snapshot was taken at PR head `32c34a81`. The
second-round implementation series described by the outcome table below runs
through `446de082`; the individual detailed entries preserve the initial
investigation and proposed response so the reasoning remains reviewable.

### Commit and comment order

| Branch order | Reviewed commit | Authored | Subject | New comments |
|---:|---|---|---|---:|
| 1 | `c05614aa` | 2026-07-24 22:31 | EC618: track PR 3075 review follow-up | 1 |
| 2 | `78c45c50` | 2026-07-24 22:48 | EC618: normalize Toit documentation | 2–4 |
| 3 | `1358b745` | 2026-07-25 00:26 | FreeRTOS: share condition variables | 6 |
| 4 | `be687dab` | 2026-07-25 00:43 | EC618: continue long deep sleeps | 7 |
| 5 | `5ccc5a15` | 2026-07-25 01:06 | EC618: enforce GPIO pad ownership | 5, 8–10 |
| 6 | `3f1f44b5` | 2026-07-25 01:20 | EC618: make GPIO alias ownership mode-aware | 11–12 |
| 7 | `f5be8964` | 2026-07-25 01:21 | EC618: harden I2C lifecycle contracts | 13–19 |
| 8 | `fdbc5191` | 2026-07-25 03:13 | EC618: lock UART controller allocation | 20 |
| 9 | `ad0e05f1` | 2026-07-25 03:22 | EC618: clarify console UART query name | 21 |
| 10 | `144df807` | 2026-07-25 04:41 | EC618: describe table-driven slot data loading | 22 |
| 11 | `58125517` | 2026-07-25 04:49 | EC618 ADC: own channels across containers | 23 |
| 12 | `24506734` | 2026-07-25 04:55 | EC618 ADC: yield while conversions run | 24–26 |
| 13 | `44b84e54` | 2026-07-25 13:17 | EC618 tests: make GPIO coordination deterministic | 27 |
| 14 | `0fb886b1` | 2026-07-25 14:48 | EC618 UART: signal physical TX completion | 28 |
| 15 | `2507ddda` | 2026-07-25 16:51 | EC618 SPI: own controllers across containers | 29 |
| 16 | `fba7dfa2` | 2026-07-25 20:28 | EC618 GPIO: document authoritative pad mapping | 30 |
| 17 | `e659bf0e` | 2026-07-26 00:49 | EC618 wake: use physical pad identities | 31–32 |
| 18 | `6c5fdeef` | 2026-07-26 01:39 | EC618 I2C: defer chained reads from IRQ context | 33 |
| 19 | `a4e8d8b6` | 2026-07-26 01:54 | EC618 GPIO: lock shared-bit cleanup | 34 |
| 20 | `91735f0c` | 2026-07-26 11:47 | EC618 envelopes: enforce self-contained bases | 35 |
| 21 | `90396c92` | 2026-07-26 13:02 | EC618 OTA: make image configuration transactional | 36 |
| 22 | `62e009b0` | 2026-07-26 13:15 | EC618 I2C: verify pull-up failure matrix | 37 |
| 23 | `6a0bfe68` | 2026-07-26 13:19 | EC618 helpers: own convenience peripheral pins | 38 |
| 24 | `ec93a6bc` | 2026-07-26 22:57 | EC618 slot: normalize Toit documentation | 39 |
| 25 | `1d9917ef` | 2026-07-26 23:00 | EC618 tooling: normalize relocation generator style | 40 |
| 26 | `1310e904` | 2026-07-26 23:02 | Firmware services: normalize Toit documentation | 41 |
| 27 | `58133c3e` | 2026-07-26 23:13 | EC618: reflow Toit documentation paragraphs | 42 |
| 28 | `b852411b` | 2026-07-26 23:20 | EC618 tools: finish documentation review nits | 43–44 |
| 29 | `ec262ab6` | 2026-07-26 23:30 | EC618 tests: fence protocol examples in Toitdocs | 45 |
| 30 | `3babe6e8` | 2026-07-26 23:54 | EC618 base: narrow exported slot API | 46 |
| 31 | `bbbd81cb` | 2026-07-27 21:26 | EC618 I2C: own transfers in OTA slot | 47 |
| 32 | `2659f1f4` | 2026-08-31 23:02 | runtime: add explicit platform reset API | 48 |
| 33 | `9fcd99bc` | 2026-08-31 23:16 | EC618: use resource pools for GPIO and SPI | 49–50 |

### Detailed responses

The following work is intentionally deferred, with an explicit prerequisite so
it is not lost between this fix round and the final rebase:

- **I2C common async contract (comment 13):** land the current async I2C/SPI
  stack, adapt that stack to the hybrid bus-owned/generic-transfer design, then
  put the EC618 implementation on top.
- **Integer-pin rebase (comments 11, 37–38, and 49–50):** completed after the
  master rebase. EC618 peripherals accept integers only and own their physical
  PAD reservations natively. GPIO creation atomically owns both its PAD and
  aliased controller bit; peripheral mux functions deliberately do not own the
  GPIO bit, so valid sibling routes remain independent. The temporary
  carrier-`Pin` helpers and split-lease state are gone.
- **Common console UART (comment 21):** still open. The master API now has
  `uart.Port.console`, but its native primitive remains ESP32-specific; EC618
  still needs to map its anchor-selected console onto that common API before
  the platform-specific query can be removed.
- **Landing-only documentation cleanup (comments 1 and 5):** retain this
  tracker through the next review and stack recreation, then remove review
  archaeology and resolved bring-up history before landing.
- **Orderly system shutdown (comment 48):** retain the TODO on both embedded
  firmware-upgrade providers. The current reset terminates the VM but does not
  orchestrate graceful container and system-service/network shutdown; that is
  common lifecycle work and is not implemented in this fix round.
- **Commit-stack recreation:** do not rewrite the stack during this fix round.
  First publish focused fix commits for review; squash/reorder into fewer,
  targeted commits only after that review, immediately before the rebase.

### Second-round implementation outcomes

This table is the authoritative current status. The detailed entries below
retain the context needed to review each answer without reopening GitHub.

| Comment | Outcome | Fix or prerequisite |
|---:|---|---|
| 1 | Deferred | Remove review archaeology during landing cleanup, after this review and stack recreation. |
| 2 | Resolved | `6ff640bf` spells out `offset`. |
| 3 | Resolved | `6ff640bf` states the alignment and sector-boundary assumptions in the example. |
| 4 | Resolved | `d622eaf3` removes raw mutation from the public slot API and keeps mutating primitives privileged. |
| 5 | Deferred | Remove the scope repro and resolved known-issue history during landing cleanup. |
| 6 | Explanation | The condition variable blocks scheduler/event workers, not a running Toit primitive; it matches the ESP32 abstraction. |
| 7 | Resolved | `2659f1f4` adds explicit reset plus lazy public minimum-duration constants; `446de082` tests reset and zero-duration deep-sleep causes on both platforms. |
| 8 | Resolved | `9fcd99bc` moves EC618 GPIO pad and controller-bit ownership to `ResourcePool`. |
| 9 | Resolved | `9fcd99bc` unifies hardware teardown and lease return in one atomic path. |
| 10 | Resolved | `9fcd99bc` configures output state before mux connection and adds opposite-edge capture for both initial levels. |
| 11 | Resolved after rebase | Native peripherals reserve their integer-selected PADs. GPIO creation, specifically, reserves its PAD and aliased controller bit atomically; peripheral mux functions do not reserve unrelated GPIO-register ownership. |
| 12 | Resolved | `9fcd99bc` disconnects the released alias while preserving the shared controller until its final owner closes. |
| 13 | Deferred | Land the current async I2C/SPI stack, adapt it to the recorded hybrid bus-owned/generic-transfer contract, then add EC618. |
| 14 | Resolved | `6ff640bf` collapses the I2C rollback `Defer`. |
| 15 | Resolved | `446de082` proves that `Bus.close` invalidates live children before native bus close. |
| 16 | Resolved | Duplicate of comment 15; covered by the same lifecycle test. |
| 17 | Superseded | `bbbd81cb` replaced the allocating capture with the non-allocating `PendingI2cBuffers` owner. |
| 18 | Resolved | `6ff640bf` uses the repository `expect-throw` helper. |
| 19 | Resolved for this stack | `6ff640bf` explains that the alternate route tests controller rather than pin contention; express it through the final common API after comment 13. |
| 20 | Resolved | `6ff640bf` collapses the UART rollback `Defer`. |
| 21 | Rebase | Replace the EC618-specific console query with common `Port.console` during the integer-pin/common-UART rebase. |
| 22 | Resolved | `6ff640bf` removes unnecessary capitalized prose across the affected EC618 code. |
| 23 | Resolved | `6ff640bf` collapses the ADC rollback `Defer`. |
| 24 | Resolved | `6ff640bf` uses truthiness in ADC `get`. |
| 25 | Resolved | `6ff640bf` applies the same truthiness fix in ADC `raw`. |
| 26 | Resolved | `6ff640bf` records the event-driven ADC follow-up without claiming polling is required. |
| 27 | Resolved | `6ff640bf` renames the shared physical nets independently of their UART use. |
| 28 | Explanation | Retain the UART task: physical line-idle completion is required for flush, close, and RS485 correctness. |
| 29 | Resolved | `9fcd99bc` uses a two-entry `ResourcePool` for SPI controller ownership. |
| 30 | Resolved earlier | `70e8fefe` already limits the claim to AON supply ownership and separates the wake domain. |
| 31 | Resolved | `35e98fbc` exposes all six physical wake inputs with identities and electrical/function-conflict documentation. |
| 32 | Resolved | `35e98fbc` makes native wake configuration source-index based and retains a checked pad convenience mapping. |
| 33 | Explanation | Retain the I2C task: long/chained completion and latched-BUSY recovery cannot safely execute in IRQ context. |
| 34 | Resolved | `9fcd99bc` passes the held locker through GPIO helpers and pool operations. |
| 35 | Resolved | `6ff640bf` assigns preflight checks to any OTA server/client while retaining authoritative device validation. |
| 36 | Resolved | `ae5d45da` generates the relocation table in the build through provisional link, final link, and fixed-point check. |
| 37 | Resolved after rebase | I2C receives integer PAD numbers directly, the native bus owns them, and the carrier-pin helper is removed. |
| 38 | Resolved after rebase | SPI and UART likewise receive integer PAD numbers directly and own them natively; all analogous carrier helpers are removed. |
| 39 | Resolved | `4e895044` reverts the broken slot Toitdoc normalization; comments 2–4 were reapplied separately. |
| 40 | Resolved | `4e895044` restores the relocation generator's intended Toitdoc paragraphs. |
| 41 | Resolved | `4e895044` restores both firmware service Toitdocs. |
| 42 | Resolved | `8293d4f4` reverts the broad mechanical reflow; `4e895044` completes the targeted reversions. |
| 43 | Resolved | `49994e73` keeps the mini-jag Toitdocs and wraps continuation lines correctly. |
| 44 | Resolved | `49994e73` restores idiomatic truthy null checks in the relocation generator. |
| 45 | Resolved | `49994e73` audits and wraps the protocol Toitdocs while preserving fenced examples. |
| 46 | Resolved, reviewer concern accepted | `813e402e` restores the 495-entry reviewed future-slot surface. The isolated cost is 7,344 bytes of flash and 456 bytes of RAM, too small to justify losing OTA capability. |
| 47 | Resolved | `6ff640bf` documents that ESP-IDF hardware I2C transfers data; GPIO/PCNT only observe bus framing and never drive it. |
| 48 | Resolved, TODO retained | `cce2a451` restores the orderly-shutdown TODO on ESP32, mirrors it on EC618, and removes the claim that the EC618 reset path already shuts down cleanly. Shutdown orchestration remains future common lifecycle work. |
| 49 | Resolved after rebase | Native GPIO creation takes its PAD and aliased controller bit under one held global locker, while native peripherals take only their PADs. |
| 50 | Resolved after rebase | The split lease and `owns_gpio_bit` state are removed; every GPIO resource owns both leases for its full lifetime. |

### Fix commits in review order

| Order | Commit | Purpose |
|---:|---|---|
| 1 | `8293d4f4` | Revert the broad broken Toitdoc reflow. |
| 2 | `4e895044` | Revert the remaining single-file/service Toitdoc normalizations. |
| 3 | `49994e73` | Correct the remaining mini-jag, protocol, and null-check documentation nits. |
| 4 | `6ff640bf` | Address the small code, test, naming, and documentation comments together. |
| 5 | `2659f1f4` | Add the explicit cross-platform reset API and deep-sleep minimum contract. |
| 6 | `9fcd99bc` | Move GPIO and SPI ownership to resource pools and harden GPIO transitions. |
| 7 | `35e98fbc` | Expose all physical EC618 wake inputs. |
| 8 | `d622eaf3` | Restrict public slot APIs to read-only state. |
| 9 | `ae5d45da` | Generate the slot data-relocation table during the build. |
| 10 | `813e402e` | Restore and document the reviewed future-slot symbol surface. |
| 11 | `446de082` | Add reset/deep-sleep and I2C parent-close contract tests. |
| 12 | `cce2a451` | Retain the deferred orderly-shutdown TODO on both firmware providers. |

#### 1. Pending comment `3805769238` — remove review archaeology

- **Created/anchor:** 2026-08-18 15:58 UTC, `c05614aa`,
  `docs/pr-3075-review-tracker.md`.
- **Context:** The tracker and known-issues documents currently preserve a
  great deal of first-round reasoning, stale failures, and descriptions of
  implementation details that are already apparent from the code.
- **Finding:** **Open, landing cleanup.** The tracker is still useful while
  this second round is active, including for distinguishing the 47 pending
  comments from the submitted review. It should not ship as product
  documentation in its present form.
- **Planned response/action:** Keep this tracker until the review and rebase
  are closed. Before landing, remove the tracker/handover/review archaeology,
  delete stale failures and “how the code works” narratives, and move only
  durable material into the appropriate docs: hardware provenance, verified
  pin mappings, externally imposed constraints, and non-obvious maintenance
  rules.

#### 2. Pending comment `3806044892` — spell out `offset`

- **Created/anchor:** 2026-08-18 16:34 UTC, `78c45c50`,
  `lib/ec618/slot.toit`.
- **Context:** The public inactive-slot streaming example advances a local
  variable named `off` after each chunk.
- **Finding:** **Open.** The current tree still uses `off`.
- **Planned response/action:** Rename it to `offset`; this is an example, so
  clarity is more useful than abbreviation.

#### 3. Pending comment `3806048627` — state write alignment in the example

- **Created/anchor:** 2026-08-18 16:35 UTC (edited 16:38), `78c45c50`,
  `lib/ec618/slot.toit`.
- **Context:** `write-inactive-sector` accepts writes starting on a 16-byte
  boundary and confines a call to one 4 KiB sector. Sector-aligned writes are
  not required, but the example's fixed-size chunks hide that contract; the
  detailed method documentation appears only later.
- **Finding:** **Open.** The API documentation has the rule, but the example
  does not state the assumption on its chunk size and offsets.
- **Planned response/action:** Add a short comment next to the loop saying
  that each offset and non-final chunk is 16-byte aligned and that no call
  crosses a sector. Keep the complete contract on the method itself.

#### 4. Pending comment `3806063313` — public/privileged sector erase

- **Created/anchor:** 2026-08-18 16:37 UTC, `78c45c50`,
  `lib/ec618/slot.toit`.
- **Context:** The public `erase-inactive-sector` helper reaches a primitive
  that erases part of the inactive firmware slot. The higher-level firmware
  service is intended to be the ownership and policy boundary.
- **Finding:** **Open, API/security audit.** Range checks prevent erasing
  outside the inactive slot, but they do not make raw firmware mutation an
  appropriate unprivileged public API. This must be audited at the operation,
  not fixed merely by hiding this one declaration.
- **Planned response/action:** Make raw slot erase/write implementation-only
  and expose mutation through the privileged firmware service/resource. Mark
  every primitive that can change firmware state privileged (or remove the
  direct primitive boundary if the service extension can own it). Retain a
  public read-only slot view where useful.

#### 5. Pending comment `3806178934` — remove the scope repro and clean known issues

- **Created/anchor:** 2026-08-18 16:54 UTC, `5ccc5a15`,
  `tests/hw/ec618/aon-wu-scope-ec618.toit`.
- **Context:** The scope program and the long known-issues entry record the
  investigation that established the AON/wakeup behavior. Deterministic rig
  tests now cover the resulting behavior.
- **Finding:** **Open, landing cleanup.** Both files still exist.
- **Planned response/action:** Remove the oscilloscope/repro program. Audit
  `docs/ec618-known-issues.md` as part of comment 1: delete resolved debugging
  history and retain only current limitations plus concise hardware
  provenance that is not encoded in tests or public API documentation.

#### 6. Pending comment `3813895555` — does `ConditionVariable.wait` block a primitive?

- **Created/anchor:** 2026-08-19 14:29 UTC, `1358b745`,
  `src/os_freertos.h`.
- **Context:** The shared FreeRTOS condition variable waits on a native
  semaphore. The name can look like a primitive implementation blocking the
  VM task.
- **Finding:** **Explanation; no primitive blocks here.** It is used by the
  scheduler/event infrastructure through `OS::wait`/`OS::wait_us`, including
  scheduler idle waits and timer/event sources. It blocks the native worker
  that is supposed to wait, not an executing Toit primitive, and is the same
  abstraction used by the ESP32 port.
- **Planned response/action:** Reply with those call sites and keep the
  implementation. Add a concise abstraction-level comment only if the name
  remains misleading after the rebase.

#### 7. Pending comment `3814004613` — zero-duration deep sleep

- **Created/anchor:** 2026-08-19 14:42 UTC, `be687dab`,
  `src/toit_ec618.cc`.
- **Context:** EC618 cannot program a sub-second hibernate, so the current code
  clamps every duration below one second—including zero—to one second. Using
  `deep-sleep --ms=0` can be a convenient reboot idiom, but it still invokes
  the deep-sleep API and its observable wake contract matters.
- **Finding:** **Current behavior is consistent with ESP32.** ESP32 clamps zero
  to its 50 ms minimum, enters real timer-backed deep sleep, and subsequently
  reports `RESET-DEEPSLEEP` plus `WAKEUP-TIMER`. EC618 similarly clamps zero to
  its approximately one-second hardware minimum, really hibernates, and
  reports an RTC/deep-sleep wake through its platform wake API. Special-casing
  EC618 zero as a software reset would make the call faster but would change
  both its meaning and its wake/reset observations. Neither platform currently
  exposes a general application reset; firmware upgrade and several tests use
  a short/zero deep sleep as a reboot substitute.
- **Planned response/action:** Keep real deep-sleep semantics and expose an
  explicit reset operation with the same public contract on ESP32 and EC618,
  reporting a software reset rather than a deep-sleep wake. Replace reboot-only
  uses such as both firmware extensions and mini-jag with that operation; keep
  zero-duration calls that genuinely test deep sleep. Publish each platform's
  minimum as a lazily initialized public constant named
  `DEEP-SLEEP-MIN-DURATION` (`Duration --ms=50` on ESP32 and approximately one
  second on EC618) and document that shorter requested durations are rounded
  up to it. Add separate contract tests for explicit reset and for
  minimum-duration deep sleep, including the resulting reset/wakeup causes.
  The reset implementation should use a runtime-mediated exit/reset path. The
  separate TODO for gracefully stopping containers and services remains until
  common lifecycle support exists.

#### 8. Pending comment `3814596035` — use `ResourcePool` for GPIO ownership

- **Created/anchor:** 2026-08-19 15:56 UTC, `5ccc5a15`,
  `src/resources/gpio_ec618.cc`.
- **Context:** EC618 currently maintains `pads_in_use` and shared GPIO-bit
  ownership arrays manually. ESP32 expresses controller/pin availability with
  `ResourcePool` and can use an already-held outer locker for atomic compound
  changes.
- **Finding:** **Open, broad ownership refactor.** The later mode-aware changes
  make the arrays more correct but do not address the requested abstraction.
- **Planned response/action:** Replace the manual pad/controller availability
  bookkeeping with resource pools. Use the pool overload that accepts the
  outer reentrant locker so pad and shared-bit reservations remain one atomic
  operation. Audit all GPIO, PWM, UART, SPI, and I2C pad acquisition paths;
  this is not a one-line substitution at the attached location.

#### 9. Pending comment `3814630594` — dangerous `pad_release`/`release_pad` split

- **Created/anchor:** 2026-08-19 16:01 UTC, `5ccc5a15`,
  `src/resources/gpio_ec618.cc`.
- **Context:** `release_pad` updates ownership bookkeeping while `pad_release`
  changes mux/hardware state. Their similar names make it easy to invoke one
  without the other or in the wrong order.
- **Finding:** **Open; covered by comment 8's refactor.** The later locking fix
  reduces races but leaves the split lifecycle and naming hazard.
- **Planned response/action:** Make one resource teardown path own both the
  lease and hardware cleanup. Keep low-level hardware reset private and name
  it accordingly. Ensure container teardown and explicit close both exercise
  the same path.

#### 10. Pending comment `3814677073` — catch GPIO startup glitches

- **Created/anchor:** 2026-08-19 16:06 UTC, `5ccc5a15`,
  `tests/hw/ec618/gpio-multi-ec618.toit`.
- **Context:** The paired ESP32 test samples the eventual initial value after
  handshaking. That cannot detect a short opposite-level pulse while the
  EC618 pad is being muxed/configured, and its peer pull is not consistently
  in the expected output direction.
- **Finding:** **Open.** The ESP32 side checks steady state, not the transition
  the comment asks about.
- **Planned response/action:** Add a synchronized peer-side edge/pulse capture
  around `Pin --output --value=...`, with the peer pull in the same direction
  as the requested initial value. Run both initial-low and initial-high cases
  and fail on any opposite edge, not merely on the final sampled level.

#### 11. Pending comment `3824493550` — reserve the controller bit after integer-pin rebase

- **Created/anchor:** 2026-08-20 18:58 UTC (edited 19:15), `3f1f44b5`,
  `src/resources/gpio_ec618.cc`.
- **Context:** On this branch, constructing `gpio.Pin` already owns the pad.
  Master has since removed `gpio.Pin` peripheral arguments; after that rebase,
  constructing a pin/resource must reserve both the physical pad and aliased
  GPIO-controller bit itself.
- **Finding:** **Resolved after rebase, with a narrower ownership rule than the
  original wording.** GPIO resources must own both namespaces atomically.
  Native peripheral resources must own their physical PADs, but must not claim
  the aliased GPIO-controller bit while the PAD is muxed to a peripheral.
- **Response/action:** EC618 now accepts integer PAD numbers directly. GPIO
  creation takes both pools under the global locker; I2C, SPI, PWM, and UART
  retain PAD leases in their native resources and release them only after
  hardware teardown.

#### 12. Pending comment `3824619315` — releasing one of two pads sharing a GPIO bit

- **Created/anchor:** 2026-08-20 19:16 UTC, `3f1f44b5`,
  `src/resources/gpio_ec618.cc`.
- **Context:** Two physical pads can alias one GPIO controller bit. Releasing
  one must disconnect that pad without deinitializing the bit still used by
  its sibling.
- **Finding:** **Behavior currently handled, structure still open.** The
  current mode-aware path disconnects the released pad's mux, skips shared
  GPIO-register deinitialization while a sibling owns the bit, and performs
  controller cleanup when the last owner closes. Thus the released pad does
  not remain an active output. Comments 8–9 are still needed to make this
  lifecycle difficult to misuse.
- **Planned response/action:** Reply with that exact teardown sequence, add a
  two-alias release regression if not already covered, and preserve the
  defer-controller-cleanup rule in the resource-pool implementation.

#### 13. Pending comment `3824946455` — relationship to PR #3156

- **Created/anchor:** 2026-08-20 20:04 UTC, `f5be8964`, `lib/i2c.toit`.
- **Context:** This branch added an EC618-driven common-library
  start/finish transfer path. [PR #3156](https://github.com/toitlang/toit/pull/3156)
  independently migrates common I2C controller operations to a broader async
  API, including serialization, cancellation/abort, and normalized results.
- **Finding:** **Rebase/integration work; neither version should be accepted
  unchanged.** #3156 is still open and stacked on another I2C branch, so it is
  design input rather than an authoritative API. Its stronger part is the
  ownership model: the one in-flight controller operation, mutex,
  `ResourceState_`, explicit abort, probe, close, and child-device lifecycle
  all live on the `Bus`. It also exposes useful generic results such as NACK
  and timeout. That is more accurate than #3075's per-`Device` completion
  state, synchronous spinning probe, unlocked close paths, collapsed
  `HARDWARE_ERROR`, and overloaded “finish also means abort” contract.

  #3075 has the more generic device-transfer shape: one start operation taking
  `(device, tx, rx-length)` naturally represents write, read, and write-read.
  #3156 duplicates that mechanism across three start/finish primitive pairs.
  Conversely, #3075's Boolean “async supported” return and synchronous fallback
  make non-blocking behavior a runtime platform accident rather than a common
  contract.
- **Planned response/action:** Use a hybrid common design:

  1. Put serialization, completion state, current operation, and lifecycle
     locking on `Bus`.
  2. Keep one generic asynchronous device-transfer start/finish pair for
     write, read, and write-read.
  3. Give bus probe its own asynchronous start/finish pair because it has no
     persistent `Device` and returns presence rather than transfer data.
  4. Use a separate idempotent bus-level abort operation; do not overload
     finish with cancellation. Preserve #3075's operation-generation token so
     a completion racing with abort cannot satisfy the next transaction.
  5. Normalize portable results (`OK`, `NACK`, `TIMEOUT`, generic I2C error)
     while retaining platform details only where the public API deliberately
     exposes them.
  6. Require both ESP32 and EC618 controller backends to implement this async
     contract instead of dynamically falling back to a VM-blocking primitive.
  7. Close buses/devices under the same mutex so close, cancellation, and
     completion cannot free one another's resources.

  Land the current async I2C/SPI stack first, adapt it to this hybrid contract,
  and only then rebase/add the EC618 implementation. Preserve #3156's
  contention/cancellation/error tests and #3075's EC618 long-transfer,
  recovery, and hardware lifecycle tests.

#### 14. Pending comment `3825188523` — five-line I2C `Defer`

- **Created/anchor:** 2026-08-20 20:41 UTC, `f5be8964`,
  `src/resources/i2c_ec618.cc`.
- **Context:** Bus-creation rollback uses a multi-line `Defer` for one short
  conditional cleanup.
- **Finding:** **Open.** It remains needlessly expanded in the current tree.
- **Planned response/action:** Collapse it to the normal one-line `Defer`
  form used elsewhere in the repository.

#### 15. Pending comment `3825213640` — closing a bus with live devices

- **Created/anchor:** 2026-08-20 20:45 UTC, `f5be8964`,
  `src/resources/i2c_ec618.cc`.
- **Context:** The EC618 native close defensively rejects a bus with a nonzero
  device count, which makes it look as if callers must close devices manually.
- **Finding:** **Already covered by the common contract.** `Bus.close` closes
  every registered device, clears the device map, and only then invokes native
  bus close. ESP32 and PR #3156 follow the same parent-closes-children model;
  the native check is a last-line invariant guard, not public behavior.
- **Planned response/action:** Reply with that sequence and add/retain a
  contract test proving parent close invalidates its devices. Keep a debug
  assertion/defensive error in native code unless #3156 centralizes the
  invariant more cleanly.

#### 16. Pending comment `3825218588` — duplicate bus-close comment

- **Created/anchor:** 2026-08-20 20:46 UTC, `f5be8964`,
  `src/resources/i2c_ec618.cc`.
- **Context/finding:** This is an exact duplicate of comment 15 on the same
  diff.
- **Planned response/action:** Give the same answer and implementation/test
  reference as comment 15; do not create a second code change.

#### 17. Pending comment `3825223599` — five-line I2C buffer cleanup

- **Created/anchor:** 2026-08-20 20:46 UTC, `f5be8964`,
  `src/resources/i2c_ec618.cc`.
- **Context:** The reviewed code used a multi-line capturing `Defer` to free
  transfer buffers.
- **Finding:** **Superseded later by `bbbd81cb`.** That capture exceeded the
  embedded `std::function` storage and could allocate/fail. The current code
  uses the explicit `PendingI2cBuffers` RAII owner instead, so the five-line
  `Defer` no longer exists.
- **Planned response/action:** Reply that the later RAII fix removes the
  reviewed construct and keep the non-allocating owner.

#### 18. Pending comment `3825234212` — use `expect-throw`

- **Created/anchor:** 2026-08-20 20:48 UTC, `f5be8964`,
  `tests/hw/ec618/i2c-contract-ec618.toit`.
- **Context:** The test carries a custom substring-matching `expect-throws`
  helper even though the expected errors have stable exact values.
- **Finding:** **Open.** The helper remains.
- **Planned response/action:** Import and use `expect-throw` from `expect` for
  the exact `ALREADY_IN_USE`/`INVALID_ARGUMENT` results. Retain a custom helper
  only if a case genuinely needs structured inspection that `expect-throw`
  cannot express.

#### 19. Pending comment `3825241339` — direct `Bus` versus `Ec618.i2c0`

- **Created/anchor:** 2026-08-20 20:49 UTC, `f5be8964`,
  `tests/hw/ec618/i2c-contract-ec618.toit`.
- **Context:** The test opens the primary route through `Ec618.i2c0`, then
  constructs a direct `Bus` on alternate pads.
- **Finding:** **Intentional coverage, insufficiently explained.** The helper
  path tests the public convenience/lifecycle API; the direct construction
  supplies a second physical route to prove that controller ownership, not
  merely pin ownership, prevents two users of I2C0.
- **Planned response/action:** Keep both until the integer-pin/#3156 rebase,
  document that distinction in the test, then express the same two-route
  contention through the final common API.

#### 20. Pending comment `3825509082` — five-line UART `Defer`

- **Created/anchor:** 2026-08-20 21:30 UTC, `fdbc5191`,
  `src/resources/uart_ec618.cc`.
- **Context/finding:** **Open.** Controller-allocation rollback is a short
  conditional cleanup still written as a five-line `Defer`.
- **Planned response/action:** Collapse it to the repository's one-line form.

#### 21. Pending comment `3829458579` — use the post-rebase console UART API

- **Created/anchor:** 2026-08-21 10:26 UTC (edited 10:28), `ad0e05f1`,
  `docs/ec618-hw-tests.md`.
- **Context:** This branch introduced an EC618-specific `console-uart-id`.
  Master now maps stdin to the default UART and exposes the common
  `Port.console` concept.
- **Finding:** **Rebase work.** Keeping a parallel EC618 query would duplicate
  the common API.
- **Planned response/action:** On rebase, map EC618 stdin/default UART and use
  `Port.console`; remove or reduce `console-uart-id` to private boot plumbing.
  Update tests/docs to use the common API.

#### 22. Pending comment `3831152175` — unnecessary CAPITALIZED prose

- **Created/anchor:** 2026-08-21 14:42 UTC, `144df807`,
  `src/toit_ec618.cc`.
- **Context:** Comments emphasize sequencing with words such as “OWN”, “THEN”,
  and “BEFORE”. Similar emphasis was added in other EC618 implementation docs.
- **Finding:** **Open, prose audit.** Uppercase identifiers and real acronyms
  are fine; uppercase ordinary words are noisy and remain in the tree.
- **Planned response/action:** Rewrite the attached explanation in normal
  prose and audit the EC618 commits for the same style, preserving only actual
  names/acronyms and warnings whose formatting carries useful meaning.

#### 23. Pending comment `3831205148` — five-line ADC `Defer`

- **Created/anchor:** 2026-08-21 14:49 UTC, `58125517`,
  `src/resources/adc_ec618.cc`.
- **Context/finding:** **Open.** Channel-allocation rollback is still an
  expanded five-line `Defer` for one conditional call.
- **Planned response/action:** Collapse it to one line.

#### 24. Pending comment `3831748558` — idiomatic truthiness in ADC `get`

- **Created/anchor:** 2026-08-21 16:01 UTC, `24506734`,
  `lib/gpio/adc.toit`.
- **Context:** The polling path tests `result != null` before returning a
  conversion result. Numeric zero is truthy in Toit, so the comparison adds
  no useful distinction.
- **Finding:** **Open.** The current code still uses the explicit comparison.
- **Planned response/action:** Change it to `if result: return result`.

#### 25. Pending comment `3831751059` — same truthiness fix in ADC `raw`

- **Created/anchor:** 2026-08-21 16:01 UTC, `24506734`,
  `lib/gpio/adc.toit`.
- **Context/finding:** **Open.** This is the equivalent polling loop for the
  raw conversion result.
- **Planned response/action:** Apply the same idiomatic `if result` change;
  audit both paths together.

#### 26. Pending comment `3831756789` — record event-driven ADC follow-up

- **Created/anchor:** 2026-08-21 16:02 UTC, `24506734`,
  `lib/gpio/adc.toit`.
- **Context:** The implementation yields with a 1 ms sleep while the hardware
  conversion is pending. An ADC completion callback/event source could wake
  the task instead.
- **Finding:** **Open.** Polling is acceptable for this round, but there is no
  TODO and event-driven completion is technically possible.
- **Planned response/action:** Add a specific TODO to replace polling with a
  resource signal/event-source completion path; do not imply that polling is
  an unavoidable hardware constraint.

#### 27. Pending comment `3896057195` — UART-named constants in GPIO wiring

- **Created/anchor:** 2026-08-31 15:48 UTC, `44b84e54`,
  `tests/hw/ec618/wiring.toit`.
- **Context:** GPIO tests reuse physical nets whose constants are named
  `ESP32-UART2-RX-NET-PINS`/`TX`, even when UART is irrelevant.
- **Finding:** **Open.** The sharing is intentional, but the names incorrectly
  make UART the identity of a physical wire.
- **Planned response/action:** Rename the constants after the physical
  EC618/ESP32 pads or rig net, then derive UART and GPIO uses from those neutral
  names. Update every consumer, not just the attached GPIO table.

#### 28. Pending comment `3896175191` — UART worker/task cost

- **Created/anchor:** 2026-08-31 16:03 UTC, `0fb886b1`,
  `src/resources/uart_ec618.cc`.
- **Context:** CMSIS “send complete” means data reached the peripheral, not
  that the final stop bit left the wire. The added worker polls TEMT to make
  flush/close/RS485 completion correct. The same change also carries
  double-buffer/IRQ-chaining work for gap-free high-throughput output.
- **Finding:** **Keep the worker.** The task is not merely a pause-free-output
  optimization: it turns the controller's early “buffer accepted” callback
  into the physical line-idle completion required by flush, close, and RS485
  direction changes. Making that correctness depend on a performance flag
  would give the same API two meanings. One small shared task/queue is a
  reasonable fixed cost for correct UART semantics.
- **Planned response/action:** Retain the completion task in all modes and
  answer that it is correctness infrastructure. The existing large-buffer
  configuration may continue to control memory-heavy ring sizes, but do not
  gate the physical-drain completion path or add a second lean behavior that
  needs separate semantic tests.

#### 29. Pending comment `3896412790` — use `ResourcePool` for SPI controllers

- **Created/anchor:** 2026-08-31 16:36 UTC, `2507ddda`,
  `src/resources/spi_ec618.cc`.
- **Context:** EC618 has two SPI controllers and tracks them with a boolean
  array plus a mutex; ESP32 uses `ResourcePool` for the same exclusive lease.
- **Finding:** **Open.** The boolean lease remains in the current tree.
- **Planned response/action:** Replace it with a two-entry `ResourcePool` and
  route explicit close, construction rollback, and container teardown through
  the same take/put lifecycle.

#### 30. Pending comment `3896502938` — claim that AON GPIO keeps working asleep

- **Created/anchor:** 2026-08-31 16:48 UTC, `fba7dfa2`,
  `lib/ec618/ec618.toit`.
- **Context:** The reviewed documentation said AON GPIO pads “keep working in
  sleep modes,” which was broader than the implementation and conflated AON
  GPIO output supply with the separate wake-input domain.
- **Finding:** **Resolved later by `70e8fefe`.** Current documentation says the
  shared AON-I/O LDO is powered while GPIO/PWM owns it and distinguishes the
  separate deep-sleep wake rail. It no longer promises arbitrary GPIO
  operation during sleep.
- **Planned response/action:** Point to the later correction. Ensure the
  Toitdoc reverts in comments 39–42 do not resurrect the old claim.

#### 31. Pending comment `3896737497` — physical identities for wake inputs 0–2

- **Created/anchor:** 2026-08-31 17:19 UTC, `e659bf0e`,
  `lib/ec618/ec618.toit`.
- **Context:** The docs say wake inputs 0–2 have no pin identities. They do not
  have ordinary `gpio.Pin` identities, but the Air780E module pinout still
  identifies them: WAKEUP0 is module pin 101, wake input 1 is the VBUS/module
  pin 61 function, and wake input 2 is USIM_DET/module pin 79. Inputs 3–5 are
  the GPIO20/21/22 wake-capable route used by PAD40–42. The official GPIO guide
  also states that all six wake inputs are input-only, use the approximately
  2 V wake domain, and have special external-drive constraints.
- **Finding:** **Open; the reviewer is right.** “No ordinary `Pin`” was turned
  into the incorrect stronger claim “no physical identity.”
- **Planned response/action:** Correct the documentation and provenance using
  the [official Air780E GPIO guide](https://docs.openluat.com/air780e/luatos/hardware/design/gpio/)
  and [reference design pinout](https://docs.openluat.com/air780e/luatos/hardware/design/file/Air780E_LuatOS_Reference_Design_V20241021.pdf).
  Represent wake inputs as explicit wake-source constants/type for all six,
  with `gpio.Pin` convenience mapping only for GPIO20–22. Treat VBUS and
  USIM_DET as dedicated functions with documented conflicts rather than
  pretending they are general GPIOs.

#### 32. Pending comment `3896762173` — same wake-input identity claim in C++

- **Created/anchor:** 2026-08-31 17:23 UTC, `e659bf0e`,
  `src/wakeup_ec618.h`.
- **Context/finding:** **Open; companion to comment 31.** The internal header
  repeats the same incorrect wording and its helper accepts only a physical
  GPIO pad, making inputs 0–2 impossible to select through the public API.
- **Planned response/action:** Correct the comment and refactor configuration
  around wake-source indices 0–5. Keep a checked GPIO-pad-to-source mapping
  for PAD40–42 rather than making it the only entry point.

#### 33. Pending comment `3896851681` — I2C task cost

- **Created/anchor:** 2026-08-31 17:35 UTC, `6c5fdeef`,
  `src/resources/i2c_ec618.cc`.
- **Context:** A per-bus task defers long/chained transfer completion out of
  IRQ context and handles the hardware case where STOP leaves BUSY latched.
  Short transfers do not need that path, but the task is currently created for
  every bus.
- **Finding:** **Keep the worker.** It is part of correctness for supported
  long/dedicated transfers: work that cannot safely run in IRQ context waits
  for STOP, clears a latched BUSY engine when necessary, and only then
  publishes completion. A per-bus task with a small bounded stack is worth the
  cost and must not depend on a high-performance flag.
- **Planned response/action:** Retain the task and answer with its correctness
  role. Do not introduce a flag-dependent I2C transfer contract. The later
  common async-stack/hybrid work may change which shared event infrastructure
  runs it, but it must preserve the same completion and recovery guarantee.

#### 34. Pending comment `3897195539` — pass the held locker

- **Created/anchor:** 2026-08-31 18:24 UTC, `a4e8d8b6`,
  `src/resources/gpio_ec618.cc`.
- **Context:** `gpio_owned_by_other_pad_locked` relies on its caller already
  holding the GPIO locker but takes no parameter that demonstrates the
  precondition.
- **Finding:** **Open.** Repository resource code commonly passes the held
  `Locker` into helpers and pool operations.
- **Planned response/action:** Take `const Locker&` (or the repository's
  corresponding held-lock type) and pass it through. The resource-pool work in
  comment 8 should retain this explicit lock proof.

#### 35. Pending comment `3897245121` — Jaguar is not the only updater

- **Created/anchor:** 2026-08-31 18:31 UTC, `91735f0c`,
  `docs/ec618-base-image.md`.
- **Context:** The document assigns pre-transfer base-ID checking specifically
  to Jaguar, although any service/client that sends an OTA can perform it.
- **Finding:** **Open documentation wording.** On-device rejection remains the
  authoritative safety check regardless of client.
- **Planned response/action:** Say “OTA update servers/clients should compare
  the carried base identity with the target before transfer,” with Jaguar only
  as an example if useful. Keep the independent on-device validation.

#### 36. Pending comment `3897300641` — build generated relocation C instead of checking it in

- **Created/anchor:** 2026-08-31 18:39 UTC, `90396c92`,
  `src/toit_data_reloc.c`.
- **Context:** The file is explicitly generated by
  `tools/ec618/gen-data-reloc.toit`, but the build only checks that the tracked
  copy matches the linked slot and tells developers to regenerate manually.
- **Finding:** **Open build-system work.** It is generated data and should not
  be a reviewed source artifact. Generation depends on slot ELF addresses, so
  integrating it requires an explicit provisional-link/generate/final-link
  sequence rather than a naive pre-compile rule.
- **Planned response/action:** Remove the file from source control. Generate
  it into the build directory after the provisional slot link, compile it into
  the final link, and repeat/check to a fixed point so a changed relocation
  table cannot silently invalidate its own addresses. Keep `--check` as CI
  validation of the generated build artifact, not of a tracked C file.

#### 37. Pending comment `3897375423` — temporary I2C convenience helper

- **Created/anchor:** 2026-08-31 18:49 UTC (edited 18:51), `62e009b0`,
  `lib/ec618/ec618.toit`.
- **Context:** The helper constructs and retains `gpio.Pin` carriers because
  the pre-rebase peripheral API takes pins. Master now uses integer pins and
  native peripheral resources should own pad reservations.
- **Finding:** **Resolved after rebase.** The compatibility layer would be
  redundant with master's integer-pin API.
- **Response/action:** The carrier helper and wrapper subclass are removed.
  `i2c.Bus` receives the PAD numbers directly, and the native EC618 bus owns
  both PAD reservations through explicit close and forced teardown.

#### 38. Pending comment `3897391311` — temporary SPI convenience helper

- **Created/anchor:** 2026-08-31 18:50 UTC (edited 18:52), `6a0bfe68`,
  `lib/ec618/ec618.toit`.
- **Context/finding:** **Resolved after rebase; same issue as comment 37.** SPI
  wrapped carrier `Pin` objects solely for the old API.
- **Response/action:** SPI bus/device and UART construction now pass integers
  directly. Their native resources own all selected PADs, including SPI
  CS/DC and UART RS485 DE, and release them after hardware teardown.

#### 39. Pending comment `3897500081` — broken slot Toitdocs

- **Created/anchor:** 2026-08-31 19:04 UTC, `ec93a6bc`,
  `lib/ec618/slot.toit`.
- **Context:** In Toitdoc, an unindented continuation begins a new paragraph;
  wrapped lines in the same paragraph must be indented. The “normalization”
  commit changed intentional paragraph/continuation structure and produced
  incorrect rendering.
- **Finding:** **Open; reviewer is correct.** `ec93a6bc` changes only this file
  and is not a useful semantic change.
- **Planned response/action:** Revert the entire commit. Apply comments 2–4
  separately on top of the previously correct documentation structure.

#### 40. Pending comment `3897521555` — broken relocation-generator Toitdocs

- **Created/anchor:** 2026-08-31 19:07 UTC, `1d9917ef`,
  `tools/ec618/gen-slot-reloc.toit`.
- **Context/finding:** **Open; same Toitdoc rule.** This single-file style
  commit breaks intended paragraphs/continuations without adding behavior.
- **Planned response/action:** Revert the entire commit.

#### 41. Pending comment `3897526684` — broken firmware-service Toitdocs

- **Created/anchor:** 2026-08-31 19:08 UTC, `1310e904`,
  `system/extensions/ec618/firmware.toit`.
- **Context/finding:** **Open.** The commit changes the two firmware service
  files and mistakes intentional Toitdoc paragraphs for malformed wrapping.
- **Planned response/action:** Revert the entire commit and retain the original
  paragraph structure.

#### 42. Pending comment `3897537603` — broad broken Toitdoc reflow

- **Created/anchor:** 2026-08-31 19:09 UTC, `58133c3e`,
  `lib/ec618/ec618.toit`.
- **Context:** This is not local to the attached line. The commit mechanically
  reflows Toitdocs across EC618 libraries, firmware services, tools, mini-jag,
  and many hardware tests, often into overlong lines or incorrect paragraph
  boundaries.
- **Finding:** **Open, whole-commit scope.** Sampling the changed files confirms
  the rule was applied backwards; no independent behavior needs preserving.
- **Planned response/action:** Revert `58133c3e` wholesale, then run a focused
  Toitdoc/style audit on the remaining documentation commits. Reapply only
  demonstrably correct fixes with indented continuations and intentional blank
  paragraphs.

#### 43. Pending comment `3897547809` — mini-jag docs are useful but overlong

- **Created/anchor:** 2026-08-31 19:11 UTC, `b852411b`,
  `tests/hw/esp-tester/mini-jag.toit`.
- **Context:** Converting the public-facing mini-jag comments to Toitdocs is
  appropriate, but the replacement uses long single lines rather than normal
  Toitdoc continuation indentation.
- **Finding:** **Open; selectively fix rather than revert all of `b852411b`.**
- **Planned response/action:** Retain the Toitdoc conversion, wrap it at normal
  width, and indent continuation lines so they remain one paragraph. Audit the
  other mini-jag documentation changed by the same commit.

#### 44. Pending comment `3897554724` — restore idiomatic null checks

- **Created/anchor:** 2026-08-31 19:12 UTC, `b852411b`,
  `tools/ec618/gen-slot-reloc.toit`.
- **Context:** The commit changed `if not vm-data-start`-style checks to
  explicit `== null`. These variables can only be integers or null; integer
  zero is truthy in Toit and is not a valid linked address here.
- **Finding:** **Open; the original is idiomatic and unambiguous.**
- **Planned response/action:** Revert the explicit null comparisons to `if
  not ...` for all equivalent relocation variables, not just the attached
  one.

#### 45. Pending comment `3897564134` — overlong protocol Toitdoc

- **Created/anchor:** 2026-08-31 19:13 UTC, `ec262ab6`,
  `tests/hw/ec618/uart2-gapfree-esp32.toit`.
- **Context:** Fencing protocol examples is useful, but the prose around the
  fence was collapsed into an overlong Toitdoc line. The commit applies the
  same pattern in five ESP32-side hardware tests.
- **Finding:** **Open, commit-wide style audit.** The fences should remain;
  the surrounding prose should follow normal Toitdoc wrapping.
- **Planned response/action:** Wrap the attached paragraph with indented
  continuation lines and audit all five files in `ec262ab6` for the same issue.

#### 46. Pending comment `3897577809` — removed 286 future base symbols

- **Created/anchor:** 2026-08-31 19:15 UTC (edited 19:15), `3babe6e8`,
  `toolchains/ec618/project/src/plat_keep.c`.
- **Context:** A frozen base can satisfy future OTA slots only with symbols
  linked into that already-deployed base. The commit reduced the guaranteed
  set from 495 to the 209 used by the present slot, removing 286 possible
  future dependencies. A future missing symbol requires a new base/full flash,
  so this is a capability decision, not merely dead-code cleanup.
- **Finding/outcome:** **Resolved by restoring the reviewed surface.** An
  isolated A/B build used the same current source, GNU Arm 10.3 toolchain, and
  base-link inputs; only `plat_keep.c` changed. The 209-entry list linked with
  1,424,300 bytes of text and 574,902 bytes of BSS. The restored 495-entry
  list linked with 1,431,644 bytes of text and 575,358 bytes of BSS: a cost of
  7,344 bytes of flash text and 456 bytes of RAM. `.data` and AP image geometry
  were unchanged. That cost is not material enough to force future full
  reflashes for the 286 removed capabilities.
- **Response/action:** `813e402e` restores the explicit 495-entry surface and
  documents its reviewed driver, low-power, platform-service, networking,
  RTOS, libc/libm, and limited runtime scope. It is not generated from every
  SDK symbol; future additions still require base-contract review. Low-level
  native link capability does not make a public Toit API or bypass the
  privilege audit on Toit-facing mutation primitives. Both base documents now
  state the same compatibility policy and measurement.

#### 47. Pending comment `3897601645` — is the ESP32 slave bit-banging I2C?

- **Created/anchor:** 2026-08-31 19:18 UTC, `bbbd81cb`,
  `tests/hw/ec618/esp-idf-i2c-slave/main/i2c_slave_main.c`.
- **Context:** The peer includes a GPIO SDA-edge ISR and a PCNT counter, which
  can look like a software I2C implementation.
- **Finding:** **Explanation/documentation fix.** Data transfer is handled by
  ESP-IDF's hardware `i2c_slave` driver (`i2c_new_slave_device`, callbacks,
  and `i2c_slave_write`). GPIO/PCNT are passive instrumentation only: they
  observe SDA edges while SCL is high to distinguish START/repeated-START/STOP
  because the slave-driver callback does not expose that bus-level assertion.
  The ISR never drives SDA or SCL.
- **Planned response/action:** Keep hardware I2C, add a concise comment at the
  capture setup/handler stating that it is passive protocol instrumentation,
  and rename capture helpers if necessary so nobody mistakes them for the
  slave implementation.

#### 48. Pending comment `3903672511` — retain orderly-shutdown TODO

- **Created/anchor:** 2026-09-01 11:34 UTC, `2659f1f4`,
  `system/extensions/esp32/firmware.toit`.
- **Context:** Replacing the firmware-upgrade deep-sleep workaround with the
  explicit reset also removed an older TODO to shut the system down properly.
  The new reset result makes the scheduler kill all processes, after which the
  ESP32 run loop destroys the VM and native resource groups before calling
  `esp_restart`. That is orderly at the native runtime level, but it does not
  ask other application containers to stop cooperatively or let system
  services close network connections first. The EC618 staged-slot path may
  intentionally reset even earlier to avoid a blocked native teardown.
- **Finding:** **The reviewer is correct; retain the TODO, do not implement it
  in this round.** The explicit reset fixes the observable reset/deep-sleep
  contract but does not solve graceful whole-system shutdown.
- **Response/action:** `cce2a451` restores the TODO on the ESP32 firmware
  provider and adds the same TODO to the EC618 provider. It also corrects the
  EC618 run-loop wording that called the reset path clean beyond what it
  guarantees. The reset implementation is unchanged. A future common
  lifecycle change must stop application containers and system services before
  invoking the terminal reset, with platform-specific hard reset remaining the
  final step.

#### 49. Pending comment `3903686697` — explain GPIO outer mutex and pool pair

- **Created/anchor:** 2026-09-01 11:36 UTC, `9fcd99bc`,
  `src/resources/gpio_ec618.cc`.
- **Context:** `claim_gpio_bit` holds the global mutex while taking the GPIO
  bit from its `ResourcePool` and recording that lease on the resource. The
  same mutex also spans teardown's controller-register reset, pad disconnect,
  pool returns, and `PadGpioLock` checks across one or two shared bits.
- **Finding:** **Resolved after rebase.** Two pads that alias one GPIO bit may
  still be used simultaneously by unrelated peripheral mux functions, such as
  I2C0 on PAD14 and UART0 on PAD30. The atomic pair therefore belongs only to
  a GPIO resource; native peripheral resources reserve physical PADs without
  claiming GPIO-register ownership.
- **Response/action:** Native GPIO creation now takes the PAD and controller
  bit pools under one held locker and rolls back both on allocation failure.
  Native peripheral constructors take and retain their own PADs directly,
  without constructing carrier `Pin` resources.

#### 50. Pending comment `3903809273` — when a GPIO resource lacks the bit lease

- **Created/anchor:** 2026-09-01 11:52 UTC, `9fcd99bc`,
  `src/resources/gpio_ec618.cc`.
- **Context:** Teardown passes `resource->owns_gpio_bit()` to decide whether it
  may reset and return the shared controller bit. A resource always owns its
  physical pad, but the controller-bit lease follows the split lifecycle from
  comment 49.
- **Finding:** **Resolved after rebase.** The split state existed only because
  the old peripheral API forced PAD ownership and GPIO-bit ownership to have
  different lifetimes.
- **Response/action:** Native GPIO construction now acquires both leases
  atomically. `owns_gpio_bit`, its lazy claim path, and its conditional
  teardown are removed; GPIO teardown always resets and returns both leases.

## Response and duplicate-work audit

The authenticated GitHub snapshot contains 1,038 inline review-comment
records: 377 root comments and 661 replies. All replies were posted by
`floitsch`. The distribution by root comment is:

- 100 roots have one reply;
- 258 roots have two replies;
- 15 roots have three replies; and
- 4 roots have no reply.

Thus 273 of 377 threads have duplicate replies. GitHub still marks all 377
threads unresolved (334 are outdated); a reply beginning `done.` did not
resolve the thread in the GitHub UI.

The duplicate replies came from multiple response passes, but the repository
does not contain a duplicated implementation pass. Between the old tracker
baseline `ce3dd02c` and the authenticated PR head `3babe6e8` there are 165
single-parent commits, no merge commits, and no duplicate stable patch IDs.
The later replies usually restate the result already present in that linear
history. Where a later pass found the earlier result incomplete, it extended
or corrected it in a later commit rather than retaining two implementations:

- [r3299892126](https://github.com/toitlang/toit/pull/3075#discussion_r3299892126)
  first received an answer that kept raw GPIO numbers, then a correction to
  mode-aware ownership, and finally the actual requested resource-based
  primitive boundary in `49012c46`. The last reply supersedes the first two.
- [r3408317714](https://github.com/toitlang/toit/pull/3075#discussion_r3408317714)
  first removed the speculative jump table; a later keep-list audit in
  `3babe6e8` removed 286 exports. Comment 46 prompted an isolated measurement,
  and `813e402e` restores them because the 7,344-byte flash and 456-byte RAM
  saving did not justify losing future OTA capability.
- The repeated Toitdoc replies correspond to successive whole-tree audits and
  follow-up fixes. They are redundant as replies, but the later commits repair
  omissions rather than duplicate the same source change.
- The third replies on the UART boot-banner/AON-watchdog threads add the final
  hardware distinction and do not introduce a second driver path.

The short-lived worktree pad-lease draft was not a duplicate implementation,
but it was also not compatible with the current API: the required `gpio.Pin`
already owns the pad, so a native PWM resource cannot reserve the same pad a
second time. That draft has been removed. For the current stack, tests that
let a peripheral outlive local setup retain the carrier `Pin`; the PWM
container-teardown test now does so explicitly and carries a TODO. Native
peripheral pad leases are deferred to the integer-GPIO rebase, when EC618
peripherals will receive GPIO numbers rather than `gpio.Pin` objects and can
reserve pads in C++ without double-owning them.

The four roots without a reply are intentionally not hidden by the aggregate
counts:

- [r3516504729](https://github.com/toitlang/toit/pull/3075#discussion_r3516504729)
  and
  [r3516664910](https://github.com/toitlang/toit/pull/3075#discussion_r3516664910)
  both lead to the SPI1/UART0-pad question. The driver now selects the
  documented SPI1 ALT1 route directly, but SPI1 still needs the agreed
  hardware rewire and proof.
- [r3516626970](https://github.com/toitlang/toit/pull/3075#discussion_r3516626970)
  and
  [r3516651588](https://github.com/toitlang/toit/pull/3075#discussion_r3516651588)
  explicitly defer the common integer-GPIO API transition until the rebase.
  They remain rebase work, not resolved current-stack work.

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

No base has been released yet, so this does not prohibit correcting the base
before the first release. Platform-wide hardware fixes and stable exported-ABI
changes that genuinely belong below every slot should still be made there.
Slot-owned driver behavior should remain replaceable by OTA and should not be
moved into the base merely because changing the unreleased base is possible.

The base keep-list is an explicit reviewed compatibility surface rather than
the old jump-table prefix or an automatic export of every SDK symbol. Of its
495 entries, 209 are used by the current slot and 286 preserve foreseeable
future driver, low-power, platform-service, networking, RTOS, libc/libm, and
limited runtime capabilities. An isolated same-source build measured those
future entries at 7,344 bytes of flash text and 456 bytes of RAM, so they are
retained. A dependency outside the reviewed surface still fails the slot link
and requires an explicit base-contract change.

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
container/VM. The wake API now accepts physical `gpio.Pin` values and documents
exactly which pins are wake-capable, including the corresponding EC618 GPIO
names:

- PAD40 / `Ec618.gpio 20` maps to wakeup input 3.
- PAD41 / `Ec618.gpio 21` maps to wakeup input 4.
- PAD42 / `Ec618.gpio 22` maps to wakeup input 5.

Other ordinary GPIO pins are rejected instead of exposing the PMU's unrelated
numeric wakeup index. `Ec618.gpio` provides the convenience conversion from an
EC618 GPIO index for users bringing number-based code from another platform.
Enabling and disabling are separate operations; disable actively clears both
the PMU configuration and NVIC state before hibernate. Enabling uses the SDK's
single `GPIO_WakeupPadConfig` path, and the separate AON IO LDO is always
powered down because neither wake edges nor their pulls require it. The
dedicated WAKEUP0–2 package pins do not currently have a normal `gpio.Pin`
representation and remain outside this initial ordinary-GPIO API. Output hold
remains a separate future API after SDK/hardware proof.

The paired PAD42 regression is now a synchronized two-run state machine rather
than a long blind pulse window. Its `enabled` phase must reboot with
`wake=pad`; the immediately following `disabled` phase requires that pad wake,
disables the same physical pin, repeats the pulse, and must reboot from the RTC
timer instead. The mini-jag host recognizes an explicit expected-reboot marker
and checks the next boot's reported wake cause. The BMP280 can remain connected
because its shared power/wake net is deliberately held low between the short
pulses. Run this on hardware before closing the disable/re-sleep comments.

### 4. Which hardware rewiring and measurements are available?

This was two separate comments:

1. [r3516664910](https://github.com/toitlang/toit/pull/3075#discussion_r3516664910)
   is specifically about testing `Ec618.spi1`. The EC618 documentation and
   multiple SDK configurations confirm a valid SPI1 mapping of SSN=PAD27,
   MOSI=PAD28, MISO=PAD29, and CLK=PAD30 using ALT1. The board pinout labels
   PAD29/PAD30 only as DBG UART because it presents the normal board use and
   warns against reclaiming the debug UART; it also explicitly says CSDK can
   adjust the mux.

   The audit found a real inconsistency: `Ec618.spi1` and `spi_ec618.cc`
   accepted PAD28/29/30, while this project's `RTE_Device.h` initialized SPI1
   on the alternative valid ALT3 mapping SSN=PAD13, MOSI=PAD14, MISO=PAD15,
   CLK=PAD16. That inconsistency is now fixed: the rewritten core-SPI driver
   selects the advertised ALT1 route itself and does not consume the CMSIS RTE
   SPI pin table.

   Choose one mapping consistently. PAD28/29/30 is the preferred hardware-test
   mapping because it is the documented default and is exposed as the UART0
   cluster on `modest-affair`. The rewritten driver now selects this ALT1
   route directly instead of depending on the unrelated CMSIS RTE table.
   The test setup is:

   - transactionally select UART1 as the console;
   - move the USB UART adapter to UART1 TX/RX (PAD34/PAD33);
   - move the RC522's SPI0 nets to SPI1 PAD27/PAD28/PAD29/PAD30 while leaving
     its reset on PAD16;
   - run the same RC522 register, FIFO, DMA, cancellation, packed-prefix, and
     cleanup checks as SPI0. The ESP32 probe may share these nets, but is not
     itself the SPI slave.

   The spare 32-pin Air780E development board exposes only PAD29/PAD30 on edge
   contacts 24/25. Its official schematic routes the other two primary SPI1
   nets through the camera connector instead: PAD27/CAM_ISDA is J14 pin 3 and
   PAD28/CAM_ISCL is J14 pin 5. A separate SPI1 rig can therefore avoid
   changing `modest-affair`, provided those fine-pitch J14 contacts are
   practical to break out. The official PCB source identifies J14 as a
   bottom-contact Hirose `FH12-24S-0.5SH`: 24 contacts, 0.5 mm pitch, for a
   0.3 mm FFC. Use a bottom-contact 24-pin breakout and a 24-way 0.5 mm
   same-side cable. The UART1 control lane is edge contact 30/PAD34 to ESP32
   IO4 and edge contact 31/PAD33 from ESP32 IO16, with common ground.

   “Connect UART0 to the ESP32” therefore means connecting the physical UART0
   pad cluster and remuxing it as SPI1; UART0 is not also used as a control
   UART during the test. The software mapping is fixed; rewire and hardware
   proof are the remaining steps.

2. [r3634553044](https://github.com/toitlang/toit/pull/3075#discussion_r3634553044)
   requested an I2C electrical/failure matrix. **Resolved and hardware
   verified.** The full rig retains its framed-UART version. The smaller
   SDA/SCL/GND-only rig runs the same matrix through an autonomous ESP32
   helper whose phase markers and final acknowledgement share the I2C wires:

   - both sides' pulls disabled: an I2C operation must fail/return promptly,
     not hang, and the next operation must recover;
   - EC618 internal pulls enabled, ESP32 pulls disabled: NACK probes/transfers
     complete normally;
   - EC618 pulls disabled, ESP32 input pull-ups enabled: the same operations
     complete using only the external peer's pulls.

   All three phases passed against absent address `0x42`; both pulled phases
   were idle-high, and the ESP32 explicitly acknowledged observing the EC618
   internal pull-ups. Final doctor passed with the unchanged base ID, slot B,
   and UART0 console.

### 5. Is Clang support a requirement for this PR?

[r3609295035](https://github.com/toitlang/toit/pull/3075#discussion_r3609295035)
asks whether the EC618 toolchain can use Clang. The frozen vendor base is tied
to the xmake-pinned GCC 10.3 toolchain, and the slot now uses that same
explicit toolchain. Supporting Clang is possible only after verifying ABI,
linker, builtins, and relocation compatibility with that frozen base.

**Decision:** use the SDK-pinned Arm GNU 10.3 toolchain consistently for the
base, VM compilation, slot link, and ELF utilities. The build and CI now pass
one explicit `EC618_GCC_PATH` through xmake, CMake, the final slot link, and
the ELF tools. The living base-image documentation has been corrected to
match.

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
requests a schema and suggests a Toit-hosted URL. The repository copy lives at
`tools/schemas/ec618/partition-table/v1.json`, and every checked-in EC618
partition descriptor carries its schema ID.

**Decision:** `toit.io/schemas` is the canonical host. Proposed full schema ID:
`https://toit.io/schemas/ec618/partition-table/v1.json`. “Partition table”
describes the complete document more accurately than singular “partition”.
Keep a matching repository copy for tests. The proposed path name is accepted.
The repository copy and descriptor annotations exist. An exact copy has now
been added to `web-toit.io/static/schemas/ec618/partition-table/v1.json` and
committed there as `dbdfe99`; deployment of that web commit is the remaining
step before the canonical URL serves it.

### 7. Is `self-linux` intentional for the base release?

[r3609284626](https://github.com/toitlang/toit/pull/3075#discussion_r3609284626)
asks why the release job uses `self-linux`. Nothing in the workflow explains
an internal-runner dependency, and the normal setup action is not used.

**Decision:** use `ubuntu-latest`; there is no intended self-hosted-runner
dependency. Bootstrap and pin every required tool. Also check whether EC618
can build on the same non-Linux platforms already supported by the ESP32
build, and strive for platform parity rather than introducing a permanent
Linux-only exception. The Windows/macOS portability experiment ran on a
dedicated branch and worktree so slow CI could proceed between the other
current-stack fixes without repeatedly switching the main checkout. Both
hosted runners now pass the complete SDK, base, relocation/guard, and envelope
build, so the production EC618 workflow uses the same three-OS matrix as a
coherent change.

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
- The raw `peek32`/`poke32` bring-up primitives are removed. The concurrent
  GPIO regression now keeps three outputs open, walks combined patterns, and
  has the ESP32 observe the physical wires over the framed control protocol;
  closing the middle pad must leave both survivors driving.

## Post-audit hardware closure

The cleaned SDK base was full-flashed on 2026-07-27 and reports
`base-v3+9b21b073c2004820472d66c7a821ddf5`. On that exact base and final
slot-owned I2C implementation, the fully wired EC618/ESP32 rig passed:

- exact 1,025-byte write, read, and combined write-read data;
- the ESP32 hardware counter's repeated-START verdict of exactly two STARTs
  and one STOP;
- forced container teardown while I2C0 remained open, followed immediately by
  controller release/reacquisition and the ownership/frequency contract test;
  and
- a final device doctor without a reset: slot A, UART0, healthy base identity.

This closes the uncertainty introduced by removing the unused transfer engine
from the SDK submodule: the source-owned engine is hardware-proven against the
cleaned base, not merely link-tested against it.

## Remaining work at the audited head

The remaining work is not the 273 duplicate reply records. It is the following
code, evidence, integration, and documentation work:

1. **Finish SPI evidence.** Rewire and hardware-test SPI1 on the documented
   PAD27/PAD28/PAD29/PAD30 ALT1 route. Driver-owned whole-transfer copying may
   remain for the first version only with the current documented limitation;
   a streaming/token implementation is follow-up work if a safe progress signal
   can be exposed. The required camera-connector breakout has been ordered but
   has not arrived, so the SPI1 hardware proof is presently blocked.
2. **Complete the remaining rebase integration.** Implement the common
   `uart.Port.console` primitive for EC618 and remove the platform-specific
   public console query where tests do not require the numeric anchor value.
   Keep the current EC618 I2C implementation until the common asynchronous
   I2C/SPI stack lands, then adapt it to the recorded hybrid contract.
   Re-audit all 377 original comments after the rewrite/rebase.
3. **Finish the broad audits.** Complete the generic catch/CLI pass, the
   envelope/firmware-tool separation audit, remaining partition-record/helper
   semantics, compatibility qualification of the mixed GCC 10.2.1/10.3.1
   vendor archives, and deployment of web commit `dbdfe99`. Jaguar still needs
   the host-side base-ID preflight for an OTA extracted from an envelope; the
   on-device rejection is already present.
5. **Finish the remaining living-document audit.** The I2C, pad-lifetime,
   schema, and immediate handover status are updated here and in their focused
   documents. The broader stale-document findings already recorded in this
   tracker still need their own review pass, particularly partition design,
   UART historical issues, and the base/envelope release contract.
6. **Release only after the above review gates.** No base has been released.
   Once the current-stack fixes are accepted, prepare the coherent history,
   rebase it, repeat the audit/build/hardware matrix, then publish the first
   self-contained base/envelope pair.

## Implementation plan

The decisions above change a few details, but the following workstreams are
already clear from the complete comment pass.

1. **Address review points on the current stack.**
   Do not rebase yet. Implement one coherent addressed point at a time,
   commit it with the relevant tracker/GitHub comment links, and push it so
   the delta against the current stack can be reviewed. Broad rules such as a
   Toitdoc sweep or shared resource ownership may be one logically atomic
   commit, but must not be mixed with unrelated cleanup.

2. **Complete ownership in two API phases.**
   The first phase used carrier `gpio.Pin` objects. The completed master-rebase
   phase removes that compatibility path: native UART/I2C/SPI/PWM resources
   reserve all integer-selected PADs and release them after hardware teardown.
   GPIO resources atomically reserve the physical PAD plus the aliased
   controller bit. Temporary I2C bus-clear GPIO access stays within the bus's
   native PAD ownership and respects competing sibling GPIO-bit owners.

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
   Keep PWM cleanup and timer ownership in the channel resource, verify a
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
   running Toit between two-hour hardware intervals. Keep the watchdog's
   scheduler/light-sleep deadline model with only a normal-WDT busy-lockup
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
| GitHub response coverage | **Audit** | Authenticated snapshot: 661 replies cover 373 roots; 273 roots have duplicate replies and four have none. All 377 threads remain unresolved in GitHub, so thread resolution must follow the final code/evidence audit rather than reply count. |
| Copyright/name cleanup | **Resolved** | The three explicitly commented files use the requested 2026 contributor header, and the former chip codename no longer appears in the current tree. |
| MbedTLS include order | **Resolved** | MbedTLS configuration is selected per target by the build-wide `MBEDTLS_CONFIG_FILE`, as it is for ESP32. Every Toit header that can do so includes MbedTLS before `top.h`, preserving `top.h`'s macro cleanup; source files follow the same order unless `top.h` is required to select the platform-specific include/gating path. |
| Toitdoc/conventions | **Resolved** | Audited every PR-added Toitdoc, not just the attached lines: library comments follow imports, continuation paragraphs are indented, examples use fenced code blocks, EC618 UART mappings and restrictions live in `lib/ec618` with a signpost from the generic UART constructor, the unambiguous public console query is named `console-uart-id`, function comments in `mini-jag` are Toitdocs, and all edited sources pass `toit analyze` plus documentation generation. |
| Generic catch/CLI guidance | **Audit** | Catch-alls that can mask unexpected failures and hand-written print/exit/fail paths remain in tests and tools. |
| GPIO/pad ownership | **Resolved after rebase** | EC618 peripheral APIs accept integers only. Native UART/I2C/SPI/PWM resources reserve every selected physical PAD and return it after hardware teardown, including forced container teardown. GPIO creation atomically reserves both its PAD and aliased controller bit under the global locker; its resource always owns both. Peripheral mux functions intentionally do not reserve the GPIO bit, preserving valid simultaneous use of sibling PADs by different peripherals. I2C bus recovery operates under the bus's PAD lease and does not disturb a sibling GPIO owner. |
| ADC | **Resolved** | The two application channels use a globally locked ownership pool, may coexist with each other, and reject a second owner of the same AIO input. `SimpleResource` already registered the resource automatically; its EC618 destructor deinitializes and releases the channel on explicit close or forced container teardown. Trim/configuration initialization is serialized, and the vendor driver serializes cross-channel conversions through its IRQ-safe request queue. EC618 conversion primitives only start or harvest the per-resource request; while it is pending, the public `Adc` method sleeps/yields in Toit under a per-instance monitor instead of busy-polling inside a primitive. The rig passed forced-container cleanup followed by exclusivity, explicit close/reacquisition, and scheduler-progress coverage. |
| PWM | **Resolved** | Each channel owns its integer-selected PAD and timer through the native resource lifetime, including forced container teardown. Exact 0% and 100% use static GPIO levels; fractional factors remux and restart timer PWM. |
| I2C | **Resolved for current stack** | The OTA-slot source owns the transfer engine, IRQs, and integer-selected bus PADs; the SDK submodule retains only its stable CMSIS lifecycle plus the two required IRQ-name corrections. Transfers through 512 bytes use hardware-length FIFO mode and longer transfers use source-owned unknown-length FIFO refill/drain. Combined write-read holds the bus after the command byte and issues `START|RESTART` for the read address. The ESP32 fixture uses a hardware pulse counter gated by SCL and proved the combined operation has exactly two STARTs and one STOP; the same run passed exact 1,025-byte write, read, and combined read data. Transfer-buffer rollback is allocation-free and therefore safe with the embedded non-allocating `std::function` implementation. Existing cancellation, clock-stretch, recovery, ownership, and reuse coverage applies. Adapting this implementation to the future common hybrid asynchronous contract remains separate work. |
| TCP/lwIP | **Resolved** | The EC618 vendor archive contains and schedules the normal 250 ms TCP timer; the historical “broken Nagle timers” claim was incorrect. The shared raw-lwIP writer now follows the documented contract by calling `tcp_output` after every successful `tcp_write`; lwIP itself applies Nagle. EC618 no longer silently forces `TCP_NODELAY`. Deterministic hardware loopback coverage asserts the default on both connected and accepted sockets and sends small payloads in both directions; the cellular HTTP test carries the same default assertion when a network is registered. |
| SPI | **Open (hardware evidence)** | A globally locked lease makes each controller exclusive across containers and is returned by explicit or forced teardown. Native bus/device resources now own their integer-selected bus, CS, and DC PADs. Teardown unconditionally stops the engine, detaches its callback, frees DMA memory only afterward, and releases PADs to high impedance. The asynchronous library path has no arbitrary internal deadline; an outer cancellation runs unconditional `finally` cleanup that marks callbacks stale, stops DMA, deselects CS, and only then frees the native buffer. Read copy-back honors nonzero transfer offsets. The rig promptly cancels a 32 KiB DMA transfer that would otherwise take over 250 ms, then reuses the same controller/device. Command/address phases are packed under one CS assertion when their combined width is byte-aligned (each may be narrower); totals the 8-bit EC618 core cannot represent exactly are rejected. RC522 hardware covers a 4-bit command plus 4-bit address, including a zero-valued command. Remaining: replace whole-transfer copying with a signaled streaming/chunked design if the driver can expose progress, and prove SPI1 on hardware after rewiring. |
| UART | **Resolved** | Heap rings, DMA TX/RX, acquire/release SPSC indices, two-piece ring copies, scoped PRIMASK guards, and teardown concerns are addressed. Controller acquisition and release use the globally locked resource pool shared with the ESP32 UART design. The public routing matrix is one flat flash-resident byte array, both UART2 mappings open on the rig, native route resolution fails eagerly when flow-control pads do not match the uniquely selected TX/RX mapping, and RS485 rejects a non-GPIO DE pad before the assertion-backed configuration path. The complete newline-less `^boot.rom...` banner on UART1 is mask-ROM output at every reset, not CMSIS-init residue; it cannot be suppressed, and the unsupported abort-send call is gone. Mini-jag now owns the explicit TX/RX `Pin` objects for both its primary and rescue ports and closes them deterministically with the port, so stopping the rescue listener releases PAD25/PAD26 before a test uses them as GPIO. Final SEND_COMPLETE queues a UART drain worker that waits for TEMT in task context, releases RS485 DE, and posts the true line-idle event; `wait_tx` is a non-blocking state check. Repeated errors retain exact counters but share one queued notification per UART, preventing an error storm from filling the shared event queue. CMSIS receive-break has its own state bit and wakes the portable `wait-for-break` API without counting the framing/parity bits the low line induces. Print-UART close is non-blocking and defers final buffer/controller release to that drain worker, so DMA never retains freed staging memory; hardware verified both explicit close and forced container teardown with 2,048 bytes in flight, followed by controller reacquisition without a reset. After installing the exact final slot, the hardware regression passed all 50 framing/baud configurations, detected receive break with no error increment, counted all 256 deliberately induced parity errors, and round-tripped exact data at 1/2, 511/512/513, 1023/1024/1025, 2047–2059, and 4095–4107 bytes across the receive and both TX staging boundaries. Flush timing, gap-free TX, RS485 direction timing, and the complete reopen/set-baud sweep also pass on hardware. |
| Container wait lifecycle | **Resolved** | A container blocked in `wait` is retained in the strong `waited-on_` set until its exit notification arrives, preventing the weak service-proxy map and GC from closing it spuriously. Container identity hashes use the requested monotonic post-increment counter; the host container suite passes. |
| Cellular | **Resolved** | Public network clients share one module, and the native layer now enforces the corresponding system-wide one-connection contract. The owning event resource powers the modem down on explicit disconnect, group close, and forced container teardown; a later resource group cannot disrupt it during initialization. Hardware coverage checks cross-group rejection, disconnect/reacquisition, and killed-container cleanup without requiring network attachment. |
| Storage | **Resolved** | EC618 and host now share the complete flash-allocation-registry bucket/resource implementation under `system/extensions/shared`; only service naming and scheme dispatch stay platform-local. ESP32 deliberately keeps its small NVS/`flash-kv` implementation because it has a different persistence backend. |
| OTA/slot relocation | **Resolved** | The rewritten writer is a service resource, the provider admits only one writer, and explicit close or killed-client teardown ends relocation/program mode and releases ownership. The native write state remains process-global because program mode and the inactive slot are device-global; its privileged entry points are owned exclusively by that resource. Hardware lifecycle coverage exercises exclusivity and both cleanup paths. The separate active-firmware view owns no mapping handle or memory: EC618 XIP is permanent, the active slot is immutable until reset, and multiple mapping ranges read the same borrowed canonical view. OTA no longer turns the modem off: the old `appSetCFUN(0)` workaround was only masking a mismatched CP image and its OTA-specific primitive is gone. The separate SDK firmware-sector program/erase mode remains required around writes to the protected AP-image region. Firmware and relocation stream one sector at a time; the primitive enforces the 4 KiB maximum, so its scratch copy is bounded rather than scaling with an arbitrary caller blob. The inactive-slot writer normalizes its blob length to the same unsigned type as the slot geometry, and its subtraction-based bounds check cannot overflow. The streamed table length is bounded by the descriptor-derived slot size before the header buffer can grow, and the provisioner applies the same chained trailer bound. Public slot documentation reflects the neutral link base and table-provided slot addresses: both slots are relocated. The OTA compatibility gate and public base-ID query share one record validator/decoder. The relocation module follows the project null convention, uses standard memory operations for fixed byte regions, and names its window/stream state descriptively throughout the rewritten implementation. The shared reset helper drains the console and calls the vendor's safer `ResetECSystemReset` API rather than writing the AIRCR register directly. The VM run loop delegates the pre-teardown staged-slot reset decision to a dedicated helper, and all surviving segment/sector rounding in the EC618 primitive uses the shared `Utils` helpers. The device-side contract is settled and implemented: no OTA base update; never activate a base-mismatched slot; reject partition-geometry changes initially; retain tested transactional migration machinery for future explicit use. Jaguar's envelope-to-device base-ID preflight remains a separate host-tool integration item. |
| RTC memory | **Resolved** | It uses the SDK-managed hibernation backup application sector rather than inventing a second flash reservation. The SDK rotates the backing store, and 16 consecutive hardware hibernation cycles preserved the checksum and user bytes. |
| FreeRTOS/runtime | **Resolved** | Hardware RNG is used, and the shared entropy mixer is initialized during single-threaded VM startup after OS/mbedTLS threading setup rather than racing on first use. The unused program-memory mutex and its racy EC618 lazy initialization are removed. The hardware sub-tick clock repairs tick precision, and the common FreeRTOS condition-variable path includes the late-notification fix. Deep sleeps longer than the EC618 timer limit are persisted as RTC-backed chunks; intermediate RTC wakes restore wake-pad settings and re-enter hibernate without starting the VM, while other wake sources cancel the chain. The unavoidable EC618 task map is build-configurable and uses a checked one-entry cache. The EC618 deadline task plus normal-WDT busy-lockup backstop remain necessary because the WDT clock stops during tickless idle; the task's timed wait is capped by the remaining application deadline, so shorter sleeps reduce it and longer idle is interrupted at expiry. The subsystem lives in `watchdog_ec618.cc` rather than `primitive_ec618.cc`. Its fatal scope marker is disabled by default and only drives the physical PAD selected by `CONFIG_TOIT_EC618_WATCHDOG_FATAL_PAD`. A persisted three-stage rig test validates feeding and no-feed expiry during both application sleep and busy execution. |
| Envelopes/firmware tool | **Audit** | Platform subcommands and separate format constants exist. EC618 binary construction, slot relocation, and part parsing now live in a separate platform library behind a small generic container interface; the image-details marker scanner is shared with ESP32. The unreleased out-of-slot fallback is removed: EC618 creation requires a matching CP and SRL3 table, validates the carried `.data` image against that table, and extraction rejects an envelope missing SRL3. Current `binary`, `image`, and `ubjson` output remains byte-identical. Both ESP32 and EC618 flashing resolve their external tool before building images or creating temporary files. |
| Partition/base tools | **Open** | The anchor/provision/splice/base-ID/slot-link tools and schema validation are implemented as described in the audited result. The accepted schema remains checked in at `tools/schemas/ec618/partition-table/v1.json`; an exact web copy is committed at `web-toit.io/static/schemas/ec618/partition-table/v1.json` in `dbdfe99`. Remaining: deploy that web commit, complete descriptor/record semantics and the broader CLI/helper audit, and keep partition-size changes unavailable in the initial OTA API. |
| Build setup | **Open** | The shared action now initializes the two top-level build submodules, fetches only mbedTLS's nested source for host builds, and recurses through ESP-IDF only for ESP32 builds. The Toit-owned EC618 mbedTLS configuration lives beside the host configuration under `mbedtls/include`, rather than under `third_party`. Local rig, agent, and xmake directories are not committed and no longer impose project-wide `.gitignore` policy. The EC618 CI runs on `ubuntu-latest`, Intel macOS, and `windows-latest`; all three install the exact SDK-pinned GNU Arm 10.3-2021.10 archive with a checked SHA-256 and pass the same absolute toolchain root to xmake, CMake, the slot linker, and ELF utilities. The isolated parity run proved the complete SDK, base, relocation/guard, byte-identity, and envelope build on both non-Linux runners. The base-release workflow remains on `ubuntu-latest`. Remaining: prebuilt vendor archives contain both GCC 10.2.1 and 10.3.1 objects, which must be covered by compatibility validation. |
| Hardware tests | **Open** | Many later tests are better, but swallowed exceptions, bring-up files, and incomplete contention/cancellation cases remain across the suite. Host-specific launch commands, volatile serial names, and a stale test-status inventory are removed from the test README and test sources; the rig guide is the single operator reference, while the hardware plan owns wiring and coverage. Executable rig assignments now live in one function-keyed `wiring.toit`; paired tests import those assignments instead of owning test-local pin constants or duplicate wiring blocks. The EC618 and ESP32 RC522 tests share one register/FIFO implementation, including the correct `0x80` FIFO-flush bit; the ESP32 probe now closes every resource and turns a failed hardware verdict into a failing program. The paired-test control protocol is self-synchronizing, one-byte length-delimited, and protected by CRC-16; its host regression covers split frames, leading junk, and checksum rejection. The UART sweep and GPIO map use it for acknowledged transitions instead of sleeps, floating reads, or duplicate lines. The sustained UART, ring, and duplex tests now use the same framed control channel and shared stream/rig libraries, catch only expected deadlines, and carry every verdict over the control lane. Hardware proves 256 KiB TX plus continuous 1 MiB RX at every baud through 4 MBd, exact counted drop-newest behavior and recovery at the 32767-byte ring boundary, and simultaneous exact 256 KiB streams in both directions through 3 MBd. Mini-jag cleanup explicitly preserves both its current image and the named sleeper while removing only anonymous installed tests. The sleeper—not a platform reset-on-VM-exit policy—keeps the test VM alive if the agent container fails, so normal finished-program behavior remains unchanged. Successful tester flows restore the agent UART to 115200 before disconnecting, allowing immediate consecutive runs rather than corrupting a fast-baud agent and waiting for its watchdog. The obsolete AON register-poke and oscilloscope programs plus the PAD26 scope helper are removed; the AON output check is retained as a deterministic, rig-scoped regression, GPIO11 explicitly checks PAD26 plus rejection of a nonexistent chip alternate, and simultaneous AON PWM now measures both channel frequencies instead of masking cross-channel pulses with duty-only sampling. The consolidated GPIO test covers every rig GPIO net in both directions, models mirrored and sensor-coupled observers, handshakes its UART1-to-UART2 control-lane switch before testing UART1 pads, and validates PAD42 pull-down plus PAD34 pull-up after acknowledged peer release. |
| OS clock | **Resolved** | EC618 monotonic/system time combines the 1 kHz kernel tick with the hardware SysTick sub-count, extends the 32-bit kernel-tick wrap, and preserves accumulated deep-sleep time. The clock hardware test requires sub-millisecond progress and checks a timed wait. Condition-variable deadlines still round up to the 1 kHz RTOS tick, so their scheduling error is bounded to one millisecond. |
| Platform boundaries | **Resolved** | Shared source selects supported targets explicitly: the EC618 DROM section has an explicit branch and fatal fallback, the POSIX/ESP32 file implementation names exactly those consumers, and ESP32 firmware mapping documents its partition-relative zero offset. Firmware mapping uses the common core primitives, while ESP32 and EC618 share an embedded provider base for configuration and content fallback; their write engines stay platform-specific because IDF OTA and EC618 canonical SRL3 relocation have different transaction mechanics. EC618 entropy comes from the SDK's health-checked MP_TRNG peripheral; ESP32 independently uses `esp_fill_random`. The genuinely common FreeRTOS condition-variable mechanism is shared; each wait uses its own stack-backed static semaphore, preventing a late notification from satisfying a later wait. Thread identity and creation remain platform-specific because EC618's prebuilt FreeRTOS has no TLS slots while ESP32 has TLS and core affinity. EC618 UART uses the common UART primitive module and resource tags; obsolete platform-specific tag/unpacking entries are removed. Non-EC618 builds need concrete EC618 primitive stubs because the module table stores every function address; the stubs are generated directly from `MODULE_EC618` rather than duplicated by hand. |
| Historical comments/docs | **Open** | Production comments no longer depend on phase numbers or the deleted jump table. The focused pass now records active-UART teardown as resolved, retires the unreproduced cold-boot RX-deafness item with its evidence preserved, describes the source-owned I2C engine and repeated-START proof, removes the obsolete blob experiment, and documents GCC 10.3 for both base and slot. Remaining documentation work is narrower but real: reconcile the implemented partition design's old questions and `slot_marker` references, then review the base/envelope release contract and other historical sections against the replacement code. |

## Rewrite follow-through

| Reviewed implementation | Current implementation | Inherited review requirement |
| --- | --- | --- |
| `build-dual-image.toit`, `check-slot-pic.toit`, `gen-partitions.toit`, old `gen-plat-jt` implementations | `provision.toit`, `partitions.toit`, `gen-anchor.toit`, `gen-slot-reloc.toit`, `gen-slot-ld.toit`, `firmware.toit` | Re-audit CLI aborts, shared parsing/CRC/range helpers, examples, nullable style, authority of constants, and removal of references to deleted tools. |
| Runtime `g_plat_jt`, generated stubs, and linker wrapping | Direct symbol resolution against the selected `base.elf` via `--just-symbols`, with escaping Thumb branches represented in SRL3 | Preserve exact base/image compatibility, verify every cross-boundary direct branch is relocatable, and remove the obsolete generated header plus stale jump-table descriptions throughout source and documentation. |
| Early slot marker and fixed slot addresses | Versioned anchor plus relocation trailer | Preserve movable-layout intent, atomic update/rollback, symbol-derived geometry, bounds/signedness checks, and resource-guarded cleanup. |
| Synchronous/blob UART implementations | CMSIS DMA ring and double-buffer TX | Preserve async progress, no data loss after allocation failure, close safety, buffer-boundary coverage, break/errors, and no VM-blocking waits. |
| Early polling I2C implementation | CMSIS interrupt engine | Preserve allocation-before-I/O, true async cancellation, supported-argument validation, large transfers, clock stretching, and multi-container ownership. |
| Early flat GPIO mapping | SDK-derived pad table and GPIO-owner array | Preserve initial output, destructor cleanup, alternate pads, valid configuration checks, and add the later two-pool/lock requirement. |
| Manually reserved RTC flash | SDK hibernation backup sector | Uses the SDK's application-reserved shadow sector and wear-levelled writeback; hardware hibernation cycling verifies persistence without consuming LittleFS or a separate partition. |
| Experimental AON/GPIO scripts | Later LDO/pad implementation and regression tests | Do not keep scope archaeology; retain deterministic coverage of the original electrical behavior and deep-sleep ownership issue. |
| Separate UART1/UART2 echo helpers and newline timing protocol | Consolidated `uart-echo` plus shared framed control channel | Preserve both controllers, reopen/set-baud coverage, chunk-safe parsing, narrow failure handling, acknowledged lane changes, and exact round-trip validation. |
| Ad-hoc UART2 big-data/ring/duplex helpers | Shared `uart-stream`/`uart-rig` libraries plus the framed UART1 command server | Preserve continuous RX beyond ring capacity, exact count+CRC in both directions, deliberate overflow accounting and recovery, cooperative duplex scheduling, narrow timeout catches, and peer-reported verdicts without timing sleeps or console inspection. |

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
- **Discuss/evidence:** r3516504729 and r3516664910 no longer need a
  wiring-policy choice, and the advertised/compiled SPI1 mapping mismatch is
  fixed by direct ALT1 mux selection. They still need the agreed
  PAD27/PAD28/PAD29/PAD30 rewire and hardware proof before receiving a
  `done.` reply.
- **Resolved behavior:** precise tick rounding, EC618 hardware entropy,
  initial GPIO output level, resource-destructor cleanup, heap UART rings,
  UART-id event routing, contiguous ring copies, async UART TX, SDK-managed
  RTC backup storage, anchor-before-slots, and the anchor rename. These are
  still included in broader regression audits where applicable.
- **Superseded by later evidence:** the assumption that the duplicate GPIO11
  board labels imply two independent chip pads. The multimeter result in
  r3647233513 shows a mirrored board net; alternate-pad support remains
  required for GPIOs that actually have alternate pads.
- **Upstream/rebase:** r3516626970 and r3516651588 defer the common
  integer-GPIO API until the rebase. r3609449338’s generic UART library fix
  belongs on master. Consume those upstream results rather than carrying
  current-stack compatibility code as the final solution.
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
