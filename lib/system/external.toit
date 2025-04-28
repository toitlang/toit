// Copyright (C) 2024 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import rpc

/**
Support for sending and receiving messages between Toit and external non-Toit
  libraries.

External libraries need to be linked with the virtual machine, and need to expose
  their service through a message handler. See `include/toit/toit.h` for the
  C interface that needs to be implemented.

Services register themselves before the VM starts up, and are thus available
  as soon as the VM starts up. They can unregister themselves at any time, though.
  It is thus not guaranteed that a service is available at any given time.
*/

clients_ ::= {:}
notification-listeners_ := 0
notification-handler_/ExternalMessageHandler_? := null

/**
A client for sending and receiving messages to an external process.

Each Toit process can only create one client for any given external process.
*/
class Client:
  pid/int
  id/string
  on-notify_/Lambda? := null
  is-closed_/bool := false

  constructor.private_ .pid .id .on-notify_:

  /**
  Opens a client for an external process with the given $id.

  Throws, if no external process with the given $id is found, or if there
    already exists an open client for that $id.

  If provided, then the $on-notify lambda is registered as notification callback
    for messages from the external process. It is possible to change or delete
    the callback later by calling $set-on-notify.
  */
  static open id/string --on-notify/Lambda?=null -> Client:
    pid := pid-for-external-id_ id
    if pid == -1: throw "NOT_FOUND"
    if clients_.contains pid: throw "ALREADY_IN_USE"
    result := Client.private_ pid id on-notify
    clients_[pid] = result
    return result

  /** Closes the client. */
  close -> none:
    if is-closed_: return
    // Go through the function so that the ref-counting is correct.
    set-on-notify null
    is-closed_ = true

  /** Whether the client is already closed. */
  is-closed -> bool:
    return is-closed_

  /** Helper to convert the $message to a string or ByteArray. */
  encode-message_ message/io.Data --copy/bool -> io.Data:
    bytes/ByteArray := ?
    if message is string:
      return message
    if not copy and message is ByteArray:
      return message
    bytes = ByteArray message.byte-size
    message.write-to-byte-array bytes --at=0 0 message.byte-size
    return bytes

  /**
  Sends a notification message to the external process.

  If the $message is a string, then the receiver is guaranteed to receive
    the string data with an additional 0-terminator. The external process can
    safely interpret it as a C string. The length argument to the receiver
    does *not* include the 0-terminator.

  If $copy is true (the default) copies the given $message before sending it.
  If $copy is false, attempts to transfer ownership of the $message to the
    external process. This is only possible for $ByteArray instances that
    have their data stored in external memory, that is, not in the Toit heap.
    In that case, the $message object is neutered and can no longer be used.
  */
  notify message/io.Data --copy/bool=true:
    if is-closed_: throw "ALREADY_CLOSED"
    bytes := encode-message_ message --copy=copy
    process-send_ pid SYSTEM-EXTERNAL-NOTIFICATION_ bytes

  /**
  Sends an RPC request to the external process.

  The $function id is an integer that the external process receives as
    argument. External processes are free to interpret this id as they see fit.

  If the $message is a string, then the receiver is guaranteed to receive
    the string data with an additional 0-terminator. The external process can
    safely interpret it as a C string. The length argument to the receiver
    does *not* include the 0-terminator.

  If $copy is true (the default), copies the given $message before sending it.
  If $copy is false, attempts to transfer ownership of the $message to the
    external process. This is only possible for $ByteArray instances that
    have their data stored in external memory, that is, not in the Toit heap.
    In that case, the $message object is neutered and can no longer be used.
  */
  request function/int message/io.Data --copy/bool=true -> any:
    if is-closed_: throw "ALREADY_CLOSED"
    bytes := encode-message_ message --copy=copy
    return rpc.invoke pid function bytes

  /**
  Sets, updates or deletes the notification callback for messages from the
    external process.

  If $callback is null, then the current callback is deleted.
  If $callback is not null, then the current callback is updated.
  */
  set-on-notify callback/Lambda? -> none:
    if is-closed_: throw "ALREADY_CLOSED"
    if on-notify_ != null: notification-listeners_--
    on-notify_ = callback
    if callback:
      notification-listeners_++
    ExternalMessageHandler_.handle-listener-change

class ExternalMessageHandler_ implements SystemMessageHandler_:
  static TYPE ::= SYSTEM-EXTERNAL-NOTIFICATION_

  close -> none:
    clear-system-message-handler_ TYPE

  on-message type/int gid/int pid/int argument -> none:
    client/Client? := clients_.get pid
    if not client: return
    if client.on-notify_:
      client.on-notify_.call argument

  static handle-listener-change -> none:
    if notification-listeners_ > 0 and not notification-handler_:
      notification-handler_ = ExternalMessageHandler_
      set-system-message-handler_ TYPE notification-handler_
    else if notification-listeners_ <= 0 and notification-handler_:
      notification-handler_.close
      notification-handler_ = null
