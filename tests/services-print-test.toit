// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.services show ServiceProvider ServiceHandler
import system.api.print show PrintService
import expect

main:
  service := PrintServiceProvider
  service.install
  print "Hello"
  expect.expect-list-equals ["Hello"] service.messages
  print "World"
  expect.expect-list-equals ["World"] service.messages
  print
  expect.expect-list-equals [""] service.messages
  list := ["Test", "seems", "to", "work"]
  list.do: print it
  expect.expect-list-equals list service.messages
  service.uninstall
  // TODO(kasper): How do we handle services that come and go
  // from the client side?
  expect.expect-throw "HANDLER_NOT_FOUND": print "Oh no"

class PrintServiceProvider extends ServiceProvider
    implements PrintService ServiceHandler:
  messages_/List := []

  constructor:
    super "system/print/test" --major=1 --minor=2
    provides PrintService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == PrintService.PRINT-INDEX: return print arguments
    unreachable

  messages -> List:
    result := messages_
    messages_ = []
    return result

  print message/string -> none:
    messages_.add message
