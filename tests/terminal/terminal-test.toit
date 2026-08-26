// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import monitor

RESIZE-EVENT ::= 1 << 0

main:
  assert: terminal-is-terminal_ 0
  assert: not (terminal-is-terminal_ -1)
  assert-size_ 80 24

  mode-group := terminal-init_
  mode-resource := terminal-enter-raw_ mode-group 0
  print "RAW"
  input := io.stdin.read
  assert: input and input.size == 1 and input[0] == 'x'
  terminal-restore_ mode-resource mode-group
  print "RESTORED"

  resize-group := terminal-resize-init_
  resize-resource := terminal-resize-watch_ resize-group 0
  resize-state := monitor.ResourceState_ resize-group resize-resource
  print "WATCHING"
  assert: resize-state.wait-for-state RESIZE-EVENT == RESIZE-EVENT
  assert-size_ 100 30
  resize-state.dispose
  terminal-resize-unwatch_ resize-resource resize-group
  print "DONE"

assert-size_ expected-columns/int expected-rows/int -> none:
  size := terminal-size_ 0
  assert: size.size == 4
  assert: size[0] == expected-columns
  assert: size[1] == expected-rows
  assert: size[2] == 0
  assert: size[3] == 0

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

terminal-resize-init_:
  #primitive.terminal.resize-init

terminal-resize-watch_ group fd/int:
  #primitive.terminal.resize-watch

terminal-resize-unwatch_ resource group:
  #primitive.terminal.resize-unwatch
