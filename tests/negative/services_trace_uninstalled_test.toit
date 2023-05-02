// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.services show ServiceProvider ServiceHandler
import system.api.trace show TraceService

main:
  service := TraceServiceProvider
  service.install
  catch --trace: throw "you shouldn't see this"
  service.uninstall
  catch --trace: throw 1234
  throw 3456

class TraceServiceProvider extends ServiceProvider
    implements TraceService ServiceHandler:
  constructor:
    super "system/trace/test" --major=1 --minor=2
    provides TraceService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == TraceService.HANDLE_TRACE_INDEX:
      return handle_trace arguments
    unreachable

  handle_trace message/ByteArray -> ByteArray?:
    print "TraceService.handle_trace called"
    return null
