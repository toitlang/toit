import net.modules.tun show *

import ordered-collections show *

TOIT-TUN-READ_    ::= 1 << 0
TOIT-TUN-WRITE_   ::= 1 << 1
TOIT-TUN-ERROR_   ::= 1 << 2

main:
  socket := TunSocket

  while true:
    print "Getting packet"
    packet := socket.receive

    print packet.size
    print "Version: $(packet[0] >> 4)"
    print "Header length: $(packet[0] & 0x0F)"
    print "TOS: $(packet[1])"
    print "Total length: $(packet[2] << 8 | packet[3])"
    print "Identification: $(packet[4] << 8 | packet[5])"
    print "Flags: $(packet[6] >> 5)"
    print "Fragment offset: $((packet[6] & 0x1F) << 8 | packet[7])"
    print "TTL: $(packet[8])"
    print "Protocol: $(packet[9])"
    print "Header Checksum: $(packet[10] << 8 | packet[11])"
    print "Source IP: $(packet[12]).$(packet[13]).$(packet[14]).$(packet[15])"
    print "Destination IP: $(packet[16]).$(packet[17]).$(packet[18]).$(packet[19])"

class TunSocket:
  state_/ResourceState_? := ?

  constructor:
    group := tun-resource-group_
    id := tun-open_ group
    state_ = ResourceState_ group id
    add-finalizer this::
      this.close

  close:
    state := state_
    if state == null: return
    critical-do:
      state_ = null
      tun-close_ state.group state.resource
      state.dispose
      // Remove the finalizer installed in the constructor.
      remove-finalizer this

  receive -> ByteArray?:
    while true:
      state := ensure-state_ TOIT-TUN-READ_
      if not state: return null
      result := tun-receive_ state.group state.resource
      if result != -1: return result
      state.clear-state TOIT-TUN-READ_

  ensure-state_ bits:
    state := ensure-state_
    state-bits /int? := null
    while state-bits == null:
      state-bits = state.wait-for-state (bits | TOIT-TUN-ERROR_)
    if not state_: return null  // Closed from a different task.
    assert: state-bits != 0
    if (state-bits & TOIT-TUN-ERROR_) == 0:
      return state
    // error := tun-error_ (udp-error-number_ state.resource)
    close
    // throw error
    throw "Got error"

  ensure-state_:
    if state_: return state_
    throw "NOT_CONNECTED"

// Lazily-initialized resource group reference.
tun-resource-group_ ::= tun-init_

// Top level TUN primitives.
tun-init_:
  #primitive.tun.init

tun-receive_ tun-resource-group id:
  #primitive.tun.receive

tun-close_ tun-resource-group id:
  #primitive.tun.close

tun-open_ resource-group:
  #primitive.tun.open
