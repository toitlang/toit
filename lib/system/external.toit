// Copyright (C) 2024 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import rpc

clients_ ::= {:}
notification-listeners_ := 0
notification-handler_/ExternalMessageHandler_? := null

class Client:
  pid/int
  id/string
  notification-callback_/Lambda? := null
  is-closed_/bool := false

  constructor.private_ .pid .id:

  static open id/string -> Client?:
    pid := pid-for-external-id_ id
    if pid == -1: throw "NOT_FOUND"
    if clients_.contains pid: throw "ALREADY_IN_USE"
    result := Client.private_ pid id
    clients_[pid] = result
    return result

  close -> none:
    if is-closed_: return
    // Go through the function so that the ref-counting is correct.
    set-notification-callback null
    is-closed_ = true

  is-closed -> bool:
    return is-closed_

  /** Helper to convert the $message to a ByteArray. */
  encode-message_ message/io.Data --copy/bool -> ByteArray:
    bytes/ByteArray := ?
    if copy or message is not ByteArray:
      bytes = ByteArray message.byte-size
      message.write-to-byte-array bytes --at=0 0 message.byte-size
    else:
      bytes = message as ByteArray
    return bytes

  notify message/io.Data --copy/bool=true:
    if is-closed_: throw "ALREADY_CLOSED"
    bytes := encode-message_ message --copy=copy
    process-send_ pid SYSTEM-EXTERNAL-NOTIFICATION_ bytes

  request function/int message/ByteArray --copy/bool=true -> any:
    if is-closed_: throw "ALREADY_CLOSED"
    bytes := encode-message_ message --copy=copy
    return rpc.invoke pid function bytes

  set-notification-callback callback/Lambda? -> none:
    if is-closed_: throw "ALREADY_CLOSED"
    if notification-callback_ != null: notification-listeners_--
    notification-callback_ = callback
    if callback:
      notification-listeners_++
      ExternalMessageHandler_.start-if-necessary
    else:
      ExternalMessageHandler_.stop-if-necessary

class ExternalMessageHandler_ implements SystemMessageHandler_:
  static TYPE ::= SYSTEM-EXTERNAL-NOTIFICATION_

  close -> none:
    clear-system-message-handler_ TYPE

  on-message type/int gid/int pid/int argument -> none:
    client/Client? := clients_.get pid
    if not client: return
    if client.notification-callback_:
      client.notification-callback_.call argument

  static start-if-necessary -> none:
    if notification-listeners_ > 0 and not notification-handler_:
      notification-handler_ = ExternalMessageHandler_
      set-system-message-handler_ TYPE notification-handler_

  static stop-if-necessary -> none:
    if notification-listeners_ == 0 and notification-handler_:
      notification-handler_.close
      notification-handler_ = null
