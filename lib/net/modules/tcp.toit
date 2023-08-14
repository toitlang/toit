// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor show ResourceState_
import net
import net.tcp as net
import reader show Reader

import .dns
import .mtu

TOIT-TCP-READ_  ::= 1 << 0
TOIT-TCP-WRITE_ ::= 1 << 1
TOIT-TCP-CLOSE_ ::= 1 << 2
TOIT-TCP-ERROR_ ::= 1 << 3
TOIT-TCP-NEEDS-GC_ ::= 1 << 4

TOIT-TCP-OPTION-PORT_          ::= 1
TOIT-TCP-OPTION-PEER-PORT_     ::= 2
TOIT-TCP-OPTION-ADDRESS_       ::= 3
TOIT-TCP-OPTION-PEER-ADDRESS_  ::= 4
TOIT-TCP-OPTION-KEEP-ALIVE_    ::= 5
TOIT-TCP-OPTION-NO-DELAY_      ::= 6
TOIT-TCP-OPTION-WINDOW-SIZE_   ::= 7
TOIT-TCP-OPTION-SEND-BUFFER_   ::= 8

// Underlying TCP socket, used to implement the TcpSocket and TcpServerSocket
// classes. It provides basic support for managing the underlying resource
// state and for closing.
class TcpSocket_:
  state_ := null

  local-address -> net.SocketAddress:
    return net.SocketAddress
      net.IpAddress.parse
        get-option_ TOIT-TCP-OPTION-ADDRESS_
      get-option_ TOIT-TCP-OPTION-PORT_

  close:
    state := state_
    if state == null: return
    critical-do:
      state_ = null
      tcp-close_ state.group state.resource
      state.dispose
      // Remove the finalizer installed in [open_].
      remove-finalizer this

  mtu -> int: return TOIT-MTU-TCP

  open_ id:
    // TODO(kasper): Is this useful or should we just throw if we are already connected?
    if state_: close
    group := tcp-resource-group_
    state_ = ResourceState_ group id
    add-finalizer this::
      // TODO(kasper): We'd like to issue a "WARNING: socket was not closed" message here,
      // but the message cannot be printed on stdout because that interferes with the
      // LSP protocol.
      close

  ensure-state_ bits --error-bits=TOIT-TCP-ERROR_ [--failure]:
    state := ensure-state_
    state-bits / int? := null
    while state-bits == null:
      state-bits = state.wait-for-state (bits | error-bits | TOIT-TCP-NEEDS-GC_)
      if state-bits & TOIT-TCP-NEEDS-GC_ != 0:
        state-bits = null
        tcp-gc_ state.group
    if state-bits == 0:
      return failure.call "NOT_CONNECTED"
    if (state-bits & error-bits) == 0:
      return state
    error := tcp-error_ (tcp-error-number_ state.resource)
    close
    return failure.call error

  ensure-state_:
    if state_: return state_
    throw "NOT_CONNECTED"

  get-option_ option:
    state := ensure-state_
    return tcp-get-option_ state.group state.resource option

  set-option_ option value:
    state := ensure-state_
    return tcp-set-option_ state.group state.resource option value


class TcpServerSocket extends TcpSocket_ implements net.ServerSocket:
  backlog_ := 0

  constructor: return TcpServerSocket 10
  constructor .backlog_:

  listen address port:
    open_ (tcp-listen_ tcp-resource-group_ address port backlog_)

  accept:
    return accept: throw it

  accept [failure]:
    state := ensure-state_ TOIT-TCP-READ_ --failure=failure
    id := tcp-accept_ state.group state.resource
    if not id:
      state_.clear-state TOIT-TCP-READ_
      return null
    // Create a new client socket and return it.
    socket := TcpSocket
    socket.open_ id
    return socket


class TcpSocket extends TcpSocket_ implements net.Socket Reader:
  window-size_ := 0

  constructor: return TcpSocket 0
  constructor .window-size_:

  peer-address -> net.SocketAddress:
    return net.SocketAddress
      net.IpAddress.parse
        get-option_ TOIT-TCP-OPTION-PEER-ADDRESS_
      get-option_ TOIT-TCP-OPTION-PEER-PORT_

  window-size: return get-option_ TOIT-TCP-OPTION-WINDOW-SIZE_

  keep-alive -> bool: return get-option_ TOIT-TCP-OPTION-KEEP-ALIVE_
  keep-alive= value/bool: return set-option_ TOIT-TCP-OPTION-KEEP-ALIVE_ value

  // TODO(kasper): Remove this again.
  set-no-delay enabled/bool -> none: no-delay = enabled

  no-delay -> bool: return get-option_ TOIT-TCP-OPTION-NO-DELAY_
  no-delay= value/bool -> none: set-option_ TOIT-TCP-OPTION-NO-DELAY_ value

  // TODO(kasper): Make window size a named parameter to [connect]?
  connect hostname port:
    return connect hostname port: throw it

  connect hostname port [failure]:
    address := dns-lookup hostname
    open_ (tcp-connect_ tcp-resource-group_ address.raw port window-size_)
    error := catch:
      ensure-state_ TOIT-TCP-WRITE_ --error-bits=(TOIT-TCP-ERROR_ | TOIT-TCP-CLOSE_) --failure=failure
    if error:
      // LwIP uses the same error code, ERR_CON, for connection refused and
      // connection closed.
      if error == "Connection closed": throw "Connection refused"
      throw error

  read -> ByteArray?:
    while true:
      state := ensure-state_ TOIT-TCP-READ_ --failure=: throw it
      result := tcp-read_ state.group state.resource
      if result != -1: return result
      // TODO(anders): We could consider always clearing this after all reads.
      state.clear-state TOIT-TCP-READ_

  write data from = 0 to = data.size -> int:
    while true:
      state := ensure-state_ TOIT-TCP-WRITE_ --error-bits=(TOIT-TCP-ERROR_ | TOIT-TCP-CLOSE_) --failure=: throw it
      wrote := tcp-write_ state.group state.resource data from to
      if wrote != -1: return wrote
      state.clear-state TOIT-TCP-WRITE_

  close-write -> none:
    state := state_
    if state == null: return
    tcp-close-write_ state.group state.resource


// Lazily-initialized resource group reference.
tcp-resource-group_ ::= tcp-init_


// Top level TCP primitives.
tcp-init_:
  #primitive.tcp.init

tcp-close_ socket-resource-group descriptor:
  #primitive.tcp.close

tcp-close-write_ socket-resource-group descriptor:
  #primitive.tcp.close-write

tcp-connect_ socket-resource-group address port window-size:
  #primitive.tcp.connect

tcp-accept_ socket-resource-group descriptor:
  #primitive.tcp.accept

tcp-listen_ socket-resource-group address port backlog:
  #primitive.tcp.listen

tcp-write_ socket-resource-group descriptor data from to:
  #primitive.tcp.write

tcp-read_ socket-resource-group descriptor:
  #primitive.tcp.read

tcp-error-number_ descriptor -> int:
  #primitive.tcp.error-number

tcp-error_ error/int -> string:
  #primitive.tcp.error

tcp-get-option_ socket-resource-group id option:
  #primitive.tcp.get-option

tcp-set-option_ socket-resource-group id option value:
  #primitive.tcp.set-option

tcp-gc_ socket-resource-group:
  #primitive.tcp.gc
