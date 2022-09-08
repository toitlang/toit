// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.services show ServiceDefinition
import system.api.trace show TraceService

main:
  service := TraceServiceDefinition
  service.install
  catch --trace: throw "you shouldn't see this"
  service.uninstall
  catch --trace: throw 1234
  throw 3456

class TraceServiceDefinition extends ServiceDefinition implements TraceService:
  constructor:
    super "system/trace/test" --major=1 --minor=2
    provides TraceService.UUID TraceService.MAJOR TraceService.MINOR

  handle pid/int client/int index/int arguments/any -> any:
    if index == TraceService.HANDLE_TRACE_INDEX:
      return handle_trace arguments
    unreachable

  handle_trace message/ByteArray -> bool:
    print "TraceService.handle_trace called"
    return true
