// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor

/**
Rate limiting of repeated pairing attempts by the same peer.

$Attempts keeps a bounded history of peer identities and their recent
  pairing failures, and refuses or delays a new attempt while a peer is
  penalized. A provider creates one and shares it among all its
  `security.Pairing` objects (their `--attempts` option), which run each
  exchange through $Attempts.with-attempt so that failures are charged
  across connections, not only within one.
*/

/**
Bounds repeated pairing attempts across connection lifetimes in one provider.

Owns copies of seven-byte typed peer identities. Trusted callers must resolve
  known private addresses to the same identity before admission. Unknown changing
  addresses consume separate entries; a full history refuses new identities
  instead of evicting an active or penalized peer. This is not persistent storage.

Failures delay the next attempt by the minimum, doubling up to the maximum. After
  each quiet decay period the penalty halves, eventually reaching zero. Decay
  must be at least the maximum delay; it never shortens a running refusal period.
  Successful attempts do not erase earlier failures. Defaults are one second,
  sixty seconds and two minutes; the intervals are an implementation choice,
  not a protocol requirement. The action uses a scoped block and no extra task.
*/
class Attempts:
  capacity_/int
  minimum_/int
  maximum_/int
  decay_/int
  entries_/List := []
  mutex_/monitor.Mutex ::= monitor.Mutex

  // Core Vol 3, Part H, 2.3.6 (repeated attempts) leaves the intervals to the
  // implementation.
  constructor --capacity/int=32 --minimum/Duration=(Duration --s=1)
      --maximum/Duration=(Duration --s=60) --decay/Duration=(Duration --s=120):
    if not 1 <= capacity <= 255 or not 0 < minimum.in-us <= maximum.in-us <= decay.in-us:
      throw "INVALID_ARGUMENT"
    capacity_ = capacity
    minimum_ = minimum.in-us
    maximum_ = maximum.in-us
    decay_ = decay.in-us

  /** Runs one attempt, charging failure on exceptions or non-local unwinding. */
  with-attempt identity/ByteArray [action] -> none:
    with-attempt identity action --clock=: Time.monotonic-us

  /** Uses a trusted monotonic microsecond clock, allowing deterministic tests. */
  with-attempt identity/ByteArray [action] [--clock] -> none:
    if identity.size != 7 or not 0 <= identity[0] <= 1: throw "INVALID_ARGUMENT"
    // Copy before waiting for the mutation lock.
    owned := identity.copy
    entry/Entry_ := mutex_.do:
      now/int := clock.call
      for index := entries_.size - 1; index >= 0; index--:
        existing/Entry_ := entries_[index]
        if existing.active: continue
        existing.decay now minimum_ decay_
        if existing.delay == 0 and now >= existing.until:
          entries_.remove --at=index
      selected/Entry_? := null
      entries_.do: | existing/Entry_ |
        if existing.identity == owned: selected = existing
      if selected:
        if selected.active: throw "SMP_PAIRING_ALREADY_ACTIVE"
        if now < selected.until: throw "SMP_REPEATED_ATTEMPTS"
      else:
        if entries_.size == capacity_: throw "SMP_PAIRING_HISTORY_FULL"
        selected = Entry_ owned
        entries_.add selected
      selected.active = true
      selected
    succeeded := false
    try:
      action.call
      succeeded = true
    finally:
      critical-do --no-respect-deadline:
        mutex_.do:
          now/int := clock.call
          entry.decay now minimum_ decay_
          if not succeeded:
            entry.delay = entry.delay == 0 ? minimum_ : (min maximum_ (entry.delay * 2))
            entry.until = now + entry.delay
            entry.decay-at = now + decay_
          entry.active = false

class Entry_:
  identity/ByteArray
  active/bool := false
  delay/int := 0
  until/int := 0
  decay-at/int := 0

  constructor .identity:

  decay now/int minimum/int period/int -> none:
    while delay > 0 and now >= decay-at:
      delay = delay / 2
      if delay < minimum: delay = 0
      decay-at += period
