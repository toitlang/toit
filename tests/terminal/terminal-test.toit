// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import expect show *
import io

WINCH ::= signal-number_ "WINCH"

main:
  expect (terminal-is-terminal_ 0)
  expect (terminal-is-terminal_ 1)
  expect-not (terminal-is-terminal_ -1)
  expect-size 80 24

  group := terminal-init_
  resource := terminal-enter-raw_ group 0
  print "RAW"
  input := io.stdin.read
  expect (input and input.size == 1 and input[0] == 'x')

  expect-equals "ALREADY_IN_USE" (catch: terminal-enter-raw_ group 0)
  terminal-restore_ resource group

  resource = terminal-enter-raw_ group 0
  terminal-restore_ resource group
  print "RESTORED"

  signal-group := signal-init_
  signal-resource := signal-watch_ signal-group (Array_.ensure [WINCH])
  state := ResourceState_ signal-group signal-resource
  print "WATCHING"
  expect-equals 1 (state.wait-for-state 1)
  expect-size 100 30
  state.dispose
  signal-unwatch_ signal-resource signal-group
  print "DONE"

expect-size expected-columns/int expected-rows/int -> none:
  size := terminal-size_ 1
  expect-list-equals [expected-columns, expected-rows, 0, 0] size

terminal-init_:
  #primitive.terminal.init

terminal-is-terminal_ fd/int:
  #primitive.terminal.is-terminal

terminal-enter-raw_ group fd/int:
  #primitive.terminal.enter-raw

terminal-restore_ resource group:
  #primitive.terminal.restore

terminal-size_ fd/int:
  #primitive.terminal.size

signal-init_:
  #primitive.signal.init

signal-watch_ group numbers:
  #primitive.signal.watch

signal-unwatch_ resource group:
  #primitive.signal.unwatch

signal-number_ name/string:
  #primitive.signal.number
