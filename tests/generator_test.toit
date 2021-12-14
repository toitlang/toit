// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

import monitor

main:
  expect_equals 1 (fib 1)
  expect_equals 1 (fib 2)
  expect_equals 5 (fib 5)
  expect_equals 21 (fib 8)

  count := finite_count 2 4
  sum := 0
  count.do: sum += it
  expect_equals (2 + 3 + 4) sum

  return true // TODO(kasper): Cannot deal with non-terminating generators yet.

  count = infinite_count 0
  expect_equals 0 count.call
  expect_equals 1 count.call
  expect_equals 2 count.call

  count = infinite_count 87
  expect_equals 87 count.call
  expect_equals 88 count.call

fib n:
  if n <= 2: return 1
  return (generate:: fib n - 1).call + (generate:: fib n - 2).call

finite_count start stop:
  return generate::
    for i := start; i < stop; i++: yield i
    stop

infinite_count start:
  return generate::
    i := start
    while true: yield i++

generate code:
  result := Generator
  t := task::
    mailbox := result.mailbox_
    mailbox.receive  // Wait for initial message.
    result.is_running_ = true
    value := code.call
    result.mailbox_ = null
    mailbox.reply value
  t.tls = result
  return result

yield value:
  gen := task.tls
  if not gen: throw "Cannot yield outside generator"
  if not gen.is_running_: throw "Cannot yield from non-running generator"
  gen.is_running_ = false
  mailbox := gen.mailbox_
  mailbox.reply value
  mailbox.receive
  gen.is_running_ = true

class Generator:
  is_running_ := false
  mailbox_ := monitor.Mailbox

  is_suspended:
    return mailbox_ != null and not is_running_
  is_running:
    return mailbox_ != null and is_running_
  is_done:
    return mailbox_ == null

  call:
    if not is_suspended: throw "Cannot call non-suspended generator"
    return mailbox_.send null

  do [block]:
    while not is_done: block.call call
