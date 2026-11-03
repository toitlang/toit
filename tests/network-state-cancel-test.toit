// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import monitor

import system.base.network show NetworkModule NetworkState

/**
Module whose $disconnect yields before it closes, like a module that logs
  through a log service.
*/
class YieldingModule implements NetworkModule:
  connecting/monitor.Latch ::= monitor.Latch
  is-closed/bool := false

  connect -> none:
    connecting.set true
    sleep --ms=60_000

  disconnect -> none:
    sleep --ms=1
    is-closed = true

/**
Tests that $NetworkState.up still disconnects the module when it is canceled
  during connect.

Without a critical region, the first thing that yields in the module's
  disconnect throws in the canceled task, and the module is never closed. The
  next $NetworkState.up would then create a new module while the old one still
  holds its resources.
*/
main:
  state := NetworkState
  module := YieldingModule
  done := monitor.Latch

  client := task::
    try:
      state.up: module
    finally:
      critical-do: done.set true

  module.connecting.get
  client.cancel
  done.get

  expect module.is-closed
  expect-null state.module
