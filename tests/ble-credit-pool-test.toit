// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.acl
import expect show *
import monitor
import system

main:
  with-timeout --ms=5_000:
    limits
    quota
    fairness false
    fairness true
    release
    stopped
    drain

drain:
  pool := acl.ControllerCredits 3 --account-limit=2
  a := acl.Credits 2 --pool=pool
  b := acl.Credits 1 --pool=pool
  a.drain
  b.take
  a.take
  a.take
  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=10: a.drain
  a.complete 1
  expect-throw DEADLINE-EXCEEDED-ERROR:
    with-timeout --ms=10: a.drain
  done := monitor.Latch
  worker := task::
    a.drain
    done.set true
  try:
    a.complete 1
    done.get
    // Another connection's outstanding packet must not block this account.
    expect-equals 1 pool.outstanding
    a.take
    failed := monitor.Latch
    waiter := task:: failed.set (catch: a.drain)
    try:
      sleep --ms=1
      a.stop "stopped"
      expect-equals "stopped" failed.get
      expect-throw "stopped": a.drain
    finally:
      waiter.cancel
  finally:
    worker.cancel
    a.fail "closed"
    b.fail "closed"

stopped:
  pool := acl.ControllerCredits 2 --account-limit=2
  a := acl.Credits 2 --pool=pool
  b := acl.Credits 2 --pool=pool
  a.take
  a.take
  a.stop "stopped"
  expect-equals 2 pool.outstanding
  expect-throw "stopped": a.take
  expect-throw "HCI_ACL_ACCOUNT_LIMIT": acl.Credits 1 --pool=pool
  // Real completions still return capacity while local sending is stopped.
  a.complete 1
  b.take
  expect-equals 2 pool.outstanding
  a.fail "disconnected"
  expect-equals 1 pool.outstanding
  expect-throw "stopped": a.complete 1
  b.complete 1
  b.fail "closed"

queued pool/acl.ControllerCredits count/int:
  while pool.waiting-count != count: sleep --ms=1

limits:
  expect-throw "INVALID_ARGUMENT": acl.ControllerCredits 0
  expect-throw "INVALID_ARGUMENT": acl.ControllerCredits 1 --account-limit=17
  pool := acl.ControllerCredits 2 --account-limit=2
  expect-throw "INVALID_ARGUMENT": acl.Credits 3 --pool=pool
  a := acl.Credits 1 --pool=pool
  b := acl.Credits 2 --pool=pool
  expect-throw "HCI_ACL_ACCOUNT_LIMIT": acl.Credits 1 --pool=pool
  expect-throw "INVALID_ARGUMENT": pool.attach a
  other := acl.ControllerCredits 1
  expect-throw "INVALID_ARGUMENT": other.take a
  expect-throw "INVALID_ARGUMENT": other.release a "closed"
  a.take
  expect-throw "HCI_INVALID_ACL_CREDITS": b.complete 1
  expect-throw "HCI_INVALID_ACL_CREDITS": a.complete 2
  expect-equals 1 pool.outstanding
  a.fail "ended"
  a.fail "again"
  expect-equals 0 pool.outstanding
  expect-throw "ended": a.take
  expect-throw "ended": a.complete 0
  expect-throw "INVALID_ARGUMENT": pool.attach a
  replacement := acl.Credits 2 --pool=pool
  replacement.take
  replacement.take
  expect-equals 2 pool.outstanding
  replacement.fail "ended"
  b.fail "ended"

quota:
  pool := acl.ControllerCredits 2 --account-limit=2
  a := acl.Credits 1 --pool=pool
  b := acl.Credits 1 --pool=pool
  a.take
  done := monitor.Latch
  worker := task::
    a.take
    done.set true
  try:
    queued pool 1
    expect-throw "HCI_ACL_CREDIT_BUSY": a.take
    // A quota-blocked head must not prevent B using the remaining shared slot.
    b.take
    expect-equals 2 pool.outstanding
    b.complete 1
    a.complete 1
    done.get
    expect-equals 1 pool.outstanding
    a.complete 1
  finally:
    worker.cancel
    a.fail "closed"
    b.fail "closed"

fairness cancel-first/bool:
  pool := acl.ControllerCredits 1 --account-limit=3
  a := acl.Credits 1 --pool=pool
  b := acl.Credits 1 --pool=pool
  c := acl.Credits 1 --pool=pool
  a.take
  order := []
  first-ended := monitor.Latch
  last-ended := monitor.Latch
  first := task::
    try:
      b.take
      order.add "b"
      b.complete 1
      // An immediately repeated take cannot jump ahead of the queued C account.
      b.take
      order.add "b-again"
      b.complete 1
    finally:
      critical-do --no-respect-deadline: first-ended.set true
  queued pool 1
  last := task::
    try:
      c.take
      order.add "c"
      c.complete 1
    finally:
      critical-do --no-respect-deadline: last-ended.set true
  try:
    queued pool 2
    system.process-stats --gc
    if cancel-first:
      first.cancel
      first-ended.get
      expect-equals 1 pool.waiting-count
    a.complete 1
    first-ended.get
    last-ended.get
    expect-equals (cancel-first ? ["c"] : ["b", "c", "b-again"]) order
    expect-equals 0 pool.outstanding
    expect-equals 0 pool.waiting-count
  finally:
    first.cancel
    last.cancel
    a.fail "closed"
    b.fail "closed"
    c.fail "closed"

release:
  pool := acl.ControllerCredits 2 --account-limit=2
  a := acl.Credits 2 --pool=pool
  b := acl.Credits 1 --pool=pool
  a.take
  a.take
  ended := monitor.Latch
  waiter := task::
    error := catch: a.take
    ended.set error
  try:
    queued pool 1
    // Disconnection releases uncompleted packets and invalidates the old waiter.
    a.fail "disconnected"
    expect-equals "disconnected" ended.get
    expect-equals 0 pool.outstanding
    expect-equals 0 pool.waiting-count
    b.take
    replacement := acl.Credits 1 --pool=pool
    replacement.take
    expect-equals 2 pool.outstanding
    expect-throw "disconnected": a.complete 1
    expect-equals 2 pool.outstanding
    replacement.fail "closed"
    b.complete 1
    expect-equals 0 pool.outstanding
  finally:
    waiter.cancel
    a.fail "closed"
    b.fail "closed"
