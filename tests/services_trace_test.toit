// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.services show ServiceProvider ServiceHandlerNew
import system.api.trace show TraceService
import expect

main:
  service := TraceServiceProvider
  service.install
  catch --trace: throw 1234
  expect.expect_equals 1 service.traces.size
  catch --trace: throw 1234
  catch: throw 2345
  expect.expect_equals 1 service.traces.size
  catch --trace: throw 1234
  catch --trace: throw 2345
  expect.expect_equals 2 service.traces.size
  service.uninstall
  // Verify that the traces are still produced when the service
  // disappears while a process is still using it.
  catch --trace: throw 3456

class TraceServiceProvider extends ServiceProvider
    implements TraceService ServiceHandlerNew:
  traces_/List := []

  constructor:
    super "system/trace/test" --major=1 --minor=2
    provides TraceService.SELECTOR --handler=this --new

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == TraceService.HANDLE_TRACE_INDEX:
      return handle_trace arguments
    unreachable

  traces -> List:
    result := traces_
    traces_ = []
    return result

  handle_trace message/ByteArray -> ByteArray?:
    traces_.add message
    return null
