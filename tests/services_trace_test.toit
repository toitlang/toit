// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.services show ServiceDefinition
import system.api.trace show TraceService
import expect

main:
  service := TraceServiceDefinition
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

class TraceServiceDefinition extends ServiceDefinition implements TraceService:
  traces_/List := []

  constructor:
    super "system/trace/test" --major=1 --minor=2
    provides TraceService.UUID TraceService.MAJOR TraceService.MINOR

  handle pid/int client/int index/int arguments/any -> any:
    if index == TraceService.HANDLE_TRACE_INDEX:
      return handle_trace arguments
    unreachable

  traces -> List:
    result := traces_
    traces_ = []
    return result

  handle_trace message/ByteArray -> bool:
    traces_.add message
    return true
