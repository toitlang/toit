// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.services show ServiceClient

interface TraceService:
  static UUID  /string ::= "41c6019e-ca48-4847-9673-0869355da76a"
  static MAJOR /int    ::= 0
  static MINOR /int    ::= 1

  /**
  Attempts to handle an encoded trace message usually by printing,
    logging, or storing the message.

  Returns whether the message was handled and needs no further
    processing from the system's built-in trace message handler.
  */
  handle_trace message/ByteArray -> bool
  static HANDLE_TRACE_INDEX /int ::= 0
  // TODO(kasper): It seems nice to always have the method index
  // after the method definition to allow for documentation comments.
  // This should be fixed across the code base.

class TraceServiceClient extends ServiceClient implements TraceService:
  constructor --open/bool=true:
    super --open=open

  open -> TraceServiceClient?:
    return (open_ TraceService.UUID TraceService.MAJOR TraceService.MINOR) and this

  handle_trace message/ByteArray -> bool:
    return invoke_ TraceService.HANDLE_TRACE_INDEX message
