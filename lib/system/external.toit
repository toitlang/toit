// Copyright (C) 2024 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import rpc

class ExternalMessageHandler_ implements SystemMessageHandler_:
  static TYPE ::= SYSTEM-EXTERNAL-NOTIFICATION_
  handler/Lambda := ?

  constructor .handler:
    set-system-message-handler_ TYPE this

  close -> none:
    clear-system-message-handler_ TYPE

  on-message type/int gid/int pid/int argument -> none:
    handler.call argument

externals_ := {:}

class External:
  pid/int
  id/string
  external-message-handler_/ExternalMessageHandler_? := null
  is-closed_/bool := false

  constructor.private_ .pid .id:

  static get id/string -> External?:
    result := externals_.get id
    if result: return result
    pid := pid-for-external-id_ id
    if pid == -1: return null
    result = External.private_ pid id
    externals_[id] = result
    return result

  close -> none:
    if is-closed_: return
    clear-notification-handler
    is-closed_ = true

  is-closed -> bool:
    return is-closed_

  byte-message_ message/io.Data --copy/bool -> ByteArray:
    bytes/ByteArray := ?
    if copy or message is not ByteArray:
      bytes = ByteArray message.byte-size
      message.write-to-byte-array bytes --at=0 0 message.byte-size
    else:
      bytes = message as ByteArray
    return bytes

  notify message/io.Data --copy/bool=true:
    if is-closed_: throw "CLOSED"
    bytes := byte-message_ message --copy=copy
    process-send_ pid SYSTEM-EXTERNAL-NOTIFICATION_ bytes

  request function/int message/ByteArray --copy/bool=true -> any:
    if is-closed_: throw "CLOSED"
    bytes := byte-message_ message --copy=copy
    return rpc.invoke pid function bytes

  set-notification-handler handler/Lambda -> none:
    if is-closed_: throw "CLOSED"
    if not external-message-handler_:
      external-message-handler_ = ExternalMessageHandler_ handler
    else:
      external-message-handler_.handler = handler

  clear-notification-handler -> none:
    if is-closed_: throw "CLOSED"
    if not external-message-handler_: return
    external-message-handler_.close
    external-message-handler_ = null

