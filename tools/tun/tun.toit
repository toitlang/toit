import io
import io.byte-order show BIG-ENDIAN
import net.modules.tun show *

import ordered-collections show *

TOIT-TUN-READ_    ::= 1 << 0
TOIT-TUN-WRITE_   ::= 1 << 1
TOIT-TUN-ERROR_   ::= 1 << 2

IPV4-VERSION_ ::= 4
IPV6-VERSION_ ::= 6

// IPv4 protocol numbers.
ICMP-PROTOCOL_ ::= 1
TCP-PROTOCOL_  ::= 6
UDP-PROTOCOL_  ::= 17

// ICMP types.
ICMP-ECHO-RESPONSE_ ::= 0  // Ping response.
ICMP-DESTINATION-UNREACHABLE_ ::= 3
ICMP-ECHO-REQUEST_  ::= 8  // Ping request.

abstract class IpPacket:
  backing/ByteArray

  constructor.from-subclass .backing:

  static create backing/ByteArray -> IpPacket?:
    if (backing[0] >> 4) == IPV4-VERSION_:
      return IpV4Packet.create backing
    return null

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
  static create backing/ByteArray -> IpV4Packet?:
    assert: backing[0] >> 4 == 4
    protocol := backing[9]
    if protocol == ICMP-PROTOCOL_:
      return IcmpPacket.create backing
    if protocol == TCP-PROTOCOL_:
      return TcpPacket backing
    if protocol == UDP-PROTOCOL_:
      return UdpPacket backing
    return null

  constructor.from-subclass backing/ByteArray:
    super.from-subclass backing

  source-ip -> ByteArray:
    return backing[12..16]

  destination-ip -> ByteArray:
    return backing[16..20]

class IcmpPacket extends IpV4Packet:
  static create backing/ByteArray -> IcmpPacket?:
    if backing[20] == 8:
      return PingRequestPacket backing
    if backing[20] == 0:
      return PingResponsePacket backing
    if backing[20] == 3:
      return DestinationUnreachablePacket backing
    print "backing[20] = $backing[20]"
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
    response-backing[8] = ttl - 1
    // Calculate the checksum.
    return PingResponsePacket response-backing

  handle socket:
    response := response
    if response:
      socket.send response.backing

class PingResponsePacket extends IcmpPacket:
  constructor backing/ByteArray:
    super.from-subclass backing

  handle socket:
    s := source-ip
    print "Got ping response from $(s[0]).$(s[1]).$(s[2]).$(s[3])"

class DestinationUnreachablePacket extends IcmpPacket:
  constructor backing/ByteArray:
    super.from-subclass backing

  handle socket:
    s := source-ip
    print "Got destination unreachable from $(s[0]).$(s[1]).$(s[2]).$(s[3])"

class UdpPacket extends IpV4Packet:
  constructor backing/ByteArray:
    super.from-subclass backing

class TcpPacket extends IpV4Packet:
  constructor backing/ByteArray:
    super.from-subclass backing

main:
  socket := TunSocket

  while true:
    raw := socket.receive
    if not raw: exit 0
    if raw.size == 0: continue
    packet := IpPacket.create raw
    if packet:
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
