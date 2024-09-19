// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import monitor show ResourceState_
import net
import net.udp

import .dns
import .mtu

TOIT-UDP-READ_    ::= 1 << 0
TOIT-UDP-WRITE_   ::= 1 << 1
TOIT-UDP-ERROR_   ::= 1 << 2
TOIT-UDP-NEEDS-GC_ ::= 1 << 3

TOIT-UDP-OPTION-PORT_                ::= 1
TOIT-UDP-OPTION-ADDRESS_             ::= 2
TOIT-UDP-OPTION-BROADCAST_           ::= 3
TOIT-UDP-OPTION-MULTICAST-MEMBERSHIP ::= 4
TOIT-UDP-OPTION-MULTICAST-LOOPBACK   ::= 5
TOIT-UDP-OPTION-MULTICAST-TTL        ::= 6


class Socket implements udp.Socket:
  network_/udp.Interface
  state_/ResourceState_? := ?

  constructor network/net.Client:
    return Socket network "0.0.0.0" 0

  // The hostname is the local address to bind to.  For client sockets, pass
  // 0.0.0.0.  For server sockets pass 0.0.0.0 to listen on all interfaces, or
  // the address of a particular interface in order to listen on that
  // particular one.  The port can be zero, in which case the system picks a
  // free port.
  constructor .network_ hostname port:
    group := udp-resource-group_
    id := udp-bind_ group (dns-lookup hostname --network=network_).raw port
    state_ = ResourceState_ group id
    add-finalizer this::
      this.close

  local-address:
    state := ensure-state_
    return net.SocketAddress
      net.IpAddress.parse
        udp-get-option_ state.group state.resource TOIT-UDP-OPTION-ADDRESS_
      udp-get-option_ state.group state.resource TOIT-UDP-OPTION-PORT_

  close:
    state := state_
    if state == null: return
    critical-do:
      state_ = null
      udp-close_ state.group state.resource
      state.dispose
      // Remove the finalizer installed in the constructor.
      remove-finalizer this

  connect address/net.SocketAddress:
    state := ensure-state_
    udp-connect_ state.group state.resource address.ip.raw address.port

  read:
    return receive_ null

  receive:
    array := receive_ (Array_ 3)
    if not array: return null
    return udp.Datagram
        array[0]
        net.SocketAddress
            net.IpAddress array[1]
            array[2]

  write data/io.Data from/int=0 to/int=data.byte-size:
    send_ data from to null 0
    return to - from

  send msg:
    return send_ msg.data 0 msg.data.size msg.address.ip.raw msg.address.port

  broadcast -> bool:
    state := ensure-state_
    return udp-get-option_ state.group state.resource TOIT-UDP-OPTION-BROADCAST_

  broadcast= value/bool:
    state := ensure-state_
    return udp-set-option_ state.group state.resource TOIT-UDP-OPTION-BROADCAST_ value

  multicast-add-membership address/net.IpAddress:
    state := ensure-state_
    return udp-set-option_ state.group state.resource TOIT-UDP-OPTION-MULTICAST-MEMBERSHIP address.raw

  multicast-loopback -> bool:
    state := ensure-state_
    return udp-get-option_ state.group state.resource TOIT-UDP-OPTION-MULTICAST-LOOPBACK

  multicast-loopback= value/bool:
    state := ensure-state_
    return udp-set-option_ state.group state.resource TOIT-UDP-OPTION-MULTICAST-LOOPBACK value

  receive_ output:
    while true:
      state := ensure-state_ TOIT-UDP-READ_
      if not state: return null
      result := udp-receive_ state.group state.resource output
      if result != -1: return result
      state.clear-state TOIT-UDP-READ_

  send_ data from to address port:
    while true:
      state := ensure-state_ TOIT-UDP-WRITE_
      wrote := udp-send_ state.group state.resource data from to address port
      if wrote > 0 or wrote == to  - from: return null
      assert: wrote == -1
      state.clear-state TOIT-UDP-WRITE_

  ensure-state_ bits:
    state := ensure-state_
    state-bits /int? := null
    while state-bits == null:
      state-bits = state.wait-for-state (bits | TOIT-UDP-ERROR_ | TOIT-UDP-NEEDS-GC_)
      if state-bits & TOIT-UDP-NEEDS-GC_ != 0:
        state-bits = null
        udp-gc_ state.group
    if not state_: return null  // Closed from a different task.
    assert: state-bits != 0
    if (state-bits & TOIT-UDP-ERROR_) == 0:
      return state
    error := udp-error_ (udp-error-number_ state.resource)
    close
    throw error

  ensure-state_:
    if state_: return state_
    throw "NOT_CONNECTED"

  mtu -> int: return TOIT-MTU-UDP

// Lazily-initialized resource group reference.
udp-resource-group_ ::= udp-init_


// Top level UDP primitives.
udp-init_:
  #primitive.udp.init

udp-bind_ udp-resource-group address port:
  #primitive.udp.bind

udp-connect_ udp-resource-group id address port:
  #primitive.udp.connect

udp-receive_ udp-resource-group id output:
  #primitive.udp.receive

udp-send_ udp-resource-group id data from to address port:
  #primitive.udp.send: | error |
    if error != "WRONG_BYTES_TYPE": throw error
    bytes := ByteArray.from data
    return udp-send_ udp-resource-group id bytes 0 bytes.size address port

udp-error-number_ id:
  #primitive.udp.error-number

udp-error_ id:
  #primitive.tcp.error

udp-close_ udp-resource-group id:
  #primitive.udp.close

udp-get-option_ udp-resource-group id option:
  #primitive.udp.get-option

udp-set-option_ udp-resource-group id option value:
  #primitive.udp.set-option

udp-gc_ resource-group:
  #primitive.udp.gc
