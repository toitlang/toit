// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.api.trace show TraceService TraceServiceClient

// Cached trace service. Looked up dynamically and reset on exceptions.
service_/TraceService? := null

/**
Sends a trace message to a registered $TraceService if one exists.

The trace message is forwarded to the system's trace message handler
  if there is no registered $TraceService, or if the registered
  one fails to handle the message.
*/
send_trace_message message/ByteArray -> none:
  handled := false
  try:
    service := service_
    if service:
      handled = service.handle_trace message
    else:
      service = (TraceServiceClient --no-open).open
      if service:
        handled = service.handle_trace message
        service_ = service
  finally: | is_exception exception |
    // If the service handled the trace, we do not need to let the system
    // know about it. It is nice that others take care of our traces!
    if handled: return
    // If we got an exception during the processing, then we do not want
    // to reuse the trace service we just tried.
    if is_exception: service_ = null
    // Send the trace to the system process using the more primitive messaging
    // infrastructure. This allows the system to produce a meaningful trace
    // or print it for manual processing.
    catch: process_send_ -1 SYSTEM_TRACE_ message
    // We check for messages here in case there is no system process. This allows
    // the traces to be discovered in the message queue and handled right here.
    process_messages_
    // Stop any unwinding by returning.
    return
