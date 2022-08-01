// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import monitor show ResourceState_
import net
import net.udp as net

import .dns
import .mtu

TOIT_UDP_READ_    ::= 1 << 0
TOIT_UDP_WRITE_   ::= 1 << 1
TOIT_UDP_ERROR_   ::= 1 << 2
TOIT_UDP_NEEDS_GC_ ::= 1 << 3

TOIT_UDP_OPTION_PORT_      ::= 1
TOIT_UDP_OPTION_ADDRESS_   ::= 2
TOIT_UDP_OPTION_BROADCAST_ ::= 3

class Socket implements net.Socket:
  state_/ResourceState_? := ?

  constructor:
    return Socket "0.0.0.0" 0

  // The hostname is the local address to bind to.  For client sockets, pass
  // 0.0.0.0.  For server sockets pass 0.0.0.0 to listen on all interfaces, or
  // the address of a particular interface in order to listen on that
  // particular one.  The port can be zero, in which case the system picks a
  // free port.
  constructor hostname port:
    group := udp_resource_group_
    id := udp_bind_ group (dns_lookup hostname).raw port
    state_ = ResourceState_ group id
    add_finalizer this::
      this.close

  local_address:
    state := ensure_state_
    return net.SocketAddress
      net.IpAddress.parse
        udp_get_option_ state.group state.resource TOIT_UDP_OPTION_ADDRESS_
      udp_get_option_ state.group state.resource TOIT_UDP_OPTION_PORT_

  close:
    state := state_
    if state == null: return
    critical_do:
      state_ = null
      udp_close_ state.group state.resource
      state.dispose
      // Remove the finalizer installed in the constructor.
      remove_finalizer this

  connect address/net.SocketAddress:
    state := ensure_state_
    udp_connect_ state.group state.resource address.ip.raw address.port

  read:
    return receive_ null

  receive:
    array := receive_ (Array_ 3)
    if not array: return null
    return net.Datagram
      array[0]
      net.SocketAddress
        net.IpAddress array[1]
        array[2]

  write data from=0 to=data.size:
    send_ data from to null 0
    return to - from

  send msg:
    return send_ msg.data 0 msg.data.size msg.address.ip.raw msg.address.port

  broadcast -> bool:
    state := ensure_state_
    return udp_get_option_ state.group state.resource TOIT_UDP_OPTION_BROADCAST_

  broadcast= value/bool:
    state := ensure_state_
    return udp_set_option_ state.group state.resource TOIT_UDP_OPTION_BROADCAST_ value

  receive_ output:
    while true:
      state := ensure_state_ TOIT_UDP_READ_
      if not state: return null
      result := udp_receive_ state.group state.resource output
      if result != -1: return result
      state.clear_state TOIT_UDP_READ_

  send_ data from to address port:
    while true:
      state := ensure_state_ TOIT_UDP_WRITE_
      wrote := udp_send_ state.group state.resource data from to address port
      if wrote > 0 or wrote == to  - from: return null
      assert: wrote == -1
      state.clear_state TOIT_UDP_WRITE_

  ensure_state_ bits:
    state := ensure_state_
    state_bits /int? := null
    while state_bits == null:
      state_bits = state.wait_for_state (bits | TOIT_UDP_ERROR_ | TOIT_UDP_NEEDS_GC_)
      if state_bits & TOIT_UDP_NEEDS_GC_ != 0:
        state_bits = null
        udp_gc_ state.group
    if not state_ or not state_.resource: return null  // Closed from a different task.
    assert: state_bits != 0
    if (state_bits & TOIT_UDP_ERROR_) == 0:
      return state
    error := udp_error_ state.resource
    close
    throw error

  ensure_state_:
    if state_: return state_
    throw "NOT_CONNECTED"

  mtu -> int: return TOIT_MTU_UDP

// Lazily-initialized resource group reference.
udp_resource_group_ ::= udp_init_


// Top level UDP primitives.
udp_init_:
  #primitive.udp.init

udp_bind_ udp_resource_group address port:
  #primitive.udp.bind

udp_connect_ udp_resource_group id address port:
  #primitive.udp.connect

udp_receive_ udp_resource_group id output:
  #primitive.udp.receive

udp_send_ udp_resource_group id data from to address port:
  #primitive.udp.send

udp_error_ id:
  #primitive.udp.error

udp_close_ udp_resource_group id:
  #primitive.udp.close

udp_get_option_ udp_resource_group id option:
  #primitive.udp.get_option

udp_set_option_ udp_resource_group id option value:
  #primitive.udp.set_option

udp_gc_ resource_group:
  #primitive.udp.gc
