// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.pipe
import system

// Platform signal number, also used for pipe.kill_.
INT ::= signal-number_ "INT"

// This uses *-test-compiler.toit pattern so that we can spawn a child process
// using toit.run path passed in as args[0].
main args:
  // We don't support signals on the embedded side.
  if system.platform == system.PLATFORM-FREERTOS: return
  // On Windows we only support sending TerminateProcess that can't be caught,
  // so there isn't anything to test.
  if system.platform == system.PLATFORM-WINDOWS: return

  if args.size == 1 and args[0] == "CHILD":
    main-child
  else:
    main-parent args[0]

main-parent toit-run/string:
  test-restore toit-run
  test-reraise toit-run
  test-ignore toit-run
  test-exit-while-watching toit-run

test-restore toit-run/string:
  with-child toit-run: | child/Child |
    child.send "WATCH"
    child.send-sigint
    child.send "WAIT" --expect-reply="CAUGHT"
    child.send "UNWATCH"
    // The default disposition is back.
    child.send-sigint
    expect-equals INT (pipe.exit-signal child.wait)

test-reraise toit-run/string:
  with-child toit-run: | child/Child |
    child.send "WATCH"
    child.send-sigint
    child.send "WAIT" --expect-reply="CAUGHT"
    child.send "RAISE"
    child.send "WAIT" --expect-reply="CAUGHT"
    child.send "UNWATCH"
    child.send-only "RAISE"
    expect-equals INT (pipe.exit-signal child.wait)

test-ignore toit-run/string:
  with-child toit-run: | child/Child |
    child.send "IGNORE"
    child.send-sigint
    // An ignored signal is discarded when it is sent, so the reply proves
    // the child survived.
    child.send "PING" --expect-reply="PONG"
    child.send "WATCH"
    child.send-sigint
    child.send "WAIT" --expect-reply="CAUGHT"
    child.send "UNWATCH"
    // Unwatch should go back to ignore.
    child.send-sigint
    child.send "PING" --expect-reply="PONG"
    child.send-only "EXIT"
    expect-equals 0 (pipe.exit-code child.wait)

// Exiting with an open watcher must not crash or hang.
test-exit-while-watching toit-run/string:
  with-child toit-run: | child/Child |
    child.send "WATCH"
    child.send-sigint
    child.send "WAIT" --expect-reply="CAUGHT"
    child.send-only "EXIT"
    expect-equals 0 (pipe.exit-code child.wait)

// Executes the commands the parent sends on stdin, one per line.
main-child:
  // The parent may have inherited an ignore disposition for SIGINT, for
  // example from a background shell job.
  signal-reset_ INT
  group := signal-init_
  resource/ByteArray? := null
  state/ResourceState_? := null
  reader := pipe.stdin.in
  while command := reader.read-line:
    if command == "IGNORE":
      signal-ignore_ INT
      print "OK"
    else if command == "WATCH":
      resource = signal-watch_ group (Array_.ensure [INT])
      state = ResourceState_ group resource
      print "OK"
    else if command == "WAIT":
      expect-equals 1 (state.wait-for-state 1)
      state.clear-state 1
      print "CAUGHT"
    else if command == "UNWATCH":
      state.dispose
      signal-unwatch_ resource group
      print "OK"
    else if command == "RAISE":
      signal-raise_ INT
      print "OK"
    else if command == "PING":
      print "PONG"
    else if command == "EXIT":
      return
    else:
      throw "unknown command: $command"

with-child toit-run/string [block]:
  child := Child toit-run
  try:
    block.call child
  finally:
    // Kills the child if it is still running when $block finishes, so a
    // failing test doesn't leave it blocked.
    child.close

class Child:
  process_/pipe.Process
  exited_/bool := false

  constructor toit-run/string:
    process_ = pipe.fork
        --create-stdin
        --create-stdout
        toit-run
        [toit-run, system.program-path, "CHILD"]

  /** Sends $command and expects the $expect-reply line. */
  send command/string --expect-reply/string="OK" -> none:
    process_.stdin.out.write "$command\n"
    expect-line expect-reply

  /** Sends $command without waiting for a reply. */
  send-only command/string -> none:
    process_.stdin.out.write "$command\n"

  expect-line expected/string -> none:
    line := with-timeout --ms=10_000: process_.stdout.in.read-line
    expect-equals expected line

  send-sigint -> none:
    pipe.kill_ process_.pid INT

  wait -> int:
    result := with-timeout --ms=10_000: process_.wait
    exited_ = true
    return result

  close -> none:
    if exited_: return
    process_.kill --hard
    process_.wait
    exited_ = true

signal-init_:
  #primitive.signal.init

signal-watch_ group numbers:
  #primitive.signal.watch

signal-unwatch_ resource group:
  #primitive.signal.unwatch

signal-reset_ number/int:
  #primitive.signal.reset

signal-ignore_ number/int:
  #primitive.signal.ignore

signal-raise_ number/int:
  #primitive.signal.raise

signal-number_ name/string:
  #primitive.signal.number
