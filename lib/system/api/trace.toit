// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.services show ServiceSelector ServiceClient

interface TraceService:
  static SELECTOR ::= ServiceSelector
      --uuid="41c6019e-ca48-4847-9673-0869355da76a"
      --major=0
      --minor=1

  /**
  Attempts to handle an encoded trace message usually by printing,
    logging, or storing the message.

  Returns whether the message was handled and needs no further
    processing from the system's built-in trace message handler.
  */
  handle_trace message/ByteArray -> bool
  static HANDLE_TRACE_INDEX /int ::= 0

class TraceServiceClient extends ServiceClient implements TraceService:
  constructor selector/ServiceSelector=TraceService.SELECTOR:
    super selector

  handle_trace message/ByteArray -> bool:
    return invoke_ TraceService.HANDLE_TRACE_INDEX message
