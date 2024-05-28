import io
import io.byte-order show BIG-ENDIAN
import net.modules.tun show *

import ordered-collections show *

TOIT-TUN-READ_    ::= 1 << 0
TOIT-TUN-WRITE_   ::= 1 << 1
TOIT-TUN-ERROR_   ::= 1 << 2

abstract class IpPacket:
  backing/ByteArray

  constructor.from-subclass .backing:

  constructor backing/ByteArray:
    if (backing[0] >> 4) == 4:
      return IpV4Packet backing
    unreachable

  protocol -> int:
    return backing[9]

  handle socket -> none:
    print backing.size
    print "Version: $(backing[0] >> 4)"
    print "Header length: $(backing[0] & 0x0F)"
    print "TOS: $(backing[1])"
    print "Total length: $(backing[2] << 8 | backing[3])"
    print "Identification: $(backing[4] << 8 | backing[5])"
    print "Flags: $(backing[6] >> 5)"
    print "Fragment offset: $((backing[6] & 0x1F) << 8 | backing[7])"
    print "TTL: $(backing[8])"
    print "Protocol: $(backing[9])"
    print "Header Checksum: $(backing[10] << 8 | backing[11])"
    print "Source IP: $(backing[12]).$(backing[13]).$(backing[14]).$(backing[15])"
    print "Destination IP: $(backing[16]).$(backing[17]).$(backing[18]).$(backing[19])"

abstract class IpV4Packet extends IpPacket:
  constructor backing/ByteArray:
    assert: backing[0] >> 4 == 4
    if backing[9] == 1:
      return IcmpPacket backing
    if backing[9] == 6:
      return TcpPacket backing
    if backing[9] == 17:
      return UdpPacket backing
    throw "Unsupported protocol"

  constructor.from-subclass backing/ByteArray:
    super.from-subclass backing

  source-ip -> ByteArray:
    return backing[12..16]

  destination-ip -> ByteArray:
    return backing[16..20]

class IcmpPacket extends IpV4Packet:
  constructor backing/ByteArray:
    if backing[20] == 8:
      return PingRequestPacket backing
    unreachable

  constructor.from-subclass backing/ByteArray:
    super.from-subclass backing

class PingRequestPacket extends IcmpPacket:
  constructor backing/ByteArray:
    super.from-subclass backing

  response -> PingResponsePacket?:
    response-backing := backing.copy
    // Set the type to 0 (Echo Reply).
    response-backing[20] = 0
    // Reverse the source and destination addresses.
    response-backing.replace 12 backing 16 20
    response-backing.replace 16 backing 12 16
    // Decrement the TTL.
    ttl := BIG-ENDIAN.uint16 backing 8
    if ttl == 0: return null
    BIG-ENDIAN.put-uint16 response-backing 8 (ttl - 1)
    // Calculate the checksum.
    print "Got $backing"
    print "Put $response-backing"
    return PingResponsePacket response-backing

  handle socket:
    response := response
    if not response: return
    socket.send response.backing

class PingResponsePacket extends IcmpPacket:
  constructor backing/ByteArray:
    super.from-subclass backing

class UdpPacket extends IpV4Packet:
  constructor backing/ByteArray:
    super.from-subclass backing

class TcpPacket extends IpV4Packet:
  constructor backing/ByteArray:
    super.from-subclass backing

main:
  socket := TunSocket

  while true:
    print "Getting packet"
    raw := socket.receive
    if not raw: exit 0
    if raw.size == 0: continue
    packet := IpPacket raw
    packet.handle socket

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

  send data/io.Data -> none:
    state := ensure-state_ TOIT-TUN-WRITE_
    tun-send_ state.group state.resource data

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

tun-send_ tun-resource-group id data:
  #primitive.tun.send

tun-close_ tun-resource-group id:
  #primitive.tun.close

tun-open_ resource-group:
  #primitive.tun.open
