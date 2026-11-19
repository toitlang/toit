// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// The events primitives take a resource group and a resource from Toit code.
// Found by the primitive fuzzer: a group without an event source (the
// generic resource group) made them dereference null and crash the VM.
// They also accepted a resource of another group.

generic-group:
  #primitive.core.get-generic-resource-group

timer-init:
  #primitive.timer.init

timer-create group:
  #primitive.timer.create

timer-delete group timer:
  #primitive.timer.delete

read-state group resource:
  #primitive.events.read-state

unregister group resource:
  #primitive.events.unregister-monitor-notifier

register-monitor monitor group resource:
  #primitive.events.register-monitor-notifier

main:
  generic := generic-group
  timers := timer-init
  other-timers := timer-init
  timer := timer-create timers

  expect-throw "WRONG_OBJECT_TYPE": read-state generic timer
  expect-throw "WRONG_OBJECT_TYPE": register-monitor null generic timer
  expect-throw "WRONG_OBJECT_TYPE": unregister generic timer
  // A resource of another group.
  expect-throw "WRONG_OBJECT_TYPE": read-state other-timers timer
  expect-throw "WRONG_OBJECT_TYPE": unregister other-timers timer

  // The right group still works.
  expect-equals 0 (read-state timers timer)
  unregister timers timer
  timer-delete timers timer
