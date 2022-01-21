// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  // TODO(kasper): Task communication is deprecated. Turn these into monitor tests?

/*
SUM := 0
test_sum
  self := task
  n := 10
  master := task::
    i := 0
    n.repeat: respond: SUM += it; i++
    self.send SUM
  for i := 0; i < n; i++:
    task::
      val := master.send i * 2
      SUM -= val
  respond: it
  expect_equals
    0 + 1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9
    SUM
  print "Done!"

test_roundtrip
  last := null
  for i := 0; i <= 100; i++:
    last = task::
      while true:
        respond:
          if last: it = last.send (it + 1)
          it
  10.repeat:
    expect_equals
      100
      last.send 0
    expect_equals
      142
      last.send 42

STATE := 0
test_send_as_reply
  self := task
  b := task::
    receive: | message sender |
      // got message from [a], let [self] know.
      expect_equals "from [a]" message
      STATE = 0
      task::
        STATE = 1
        answer := self.send "from [b]"
        expect_equals "reply from [self]" answer
      yield // give the task above a chance to reach its send
      expect_equals 1 STATE
      sender.reply "reply from [b]"
  a := task::
    receive: | message sender |
      // got message from [self], let [b] know.
      answer := b.send "from [a]"
      expect_equals "reply from [b]" answer
      sender.reply "reply from [a]"
  // send a message to [a], must get a reply from [a]
  answer := a.send "from [self]"
  expect_equals "reply from [a]" answer
  respond: expect_equals "from [b]" it; "reply from [self]"

test_send_as_reply_hatched
  self := task
  b := hatch_::
    receive: | message sender |
      // got message from [a], let [self] know.
      expect_equals "from [a]" message
      STATE = 0
      task::
        STATE = 1
        answer := self.send "from [b]"
        expect_equals "reply from [self]" answer
      yield // give the task above a chance to reach its send
      expect_equals 1 STATE
      sender.reply "reply from [b]"
  a := hatch_::
    receive: | message sender |
      // got message from [self], let [b] know.
      answer := b.send "from [a]"
      expect_equals "reply from [b]" answer
      sender.reply "reply from [a]"
  // send a message to [a], must get a reply from [a]
  answer := a.send "from [self]"
  expect_equals "reply from [a]" answer
  respond: expect_equals "from [b]" it; "reply from [self]"
*/
