import io
import io.byte-order show BIG-ENDIAN
import net.modules.tun show *
import net.ip-address show IpAddress

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

  version -> int:
    return version backing

  static version backing/ByteArray -> int:
    return backing[0] >> 4

  static create backing/ByteArray -> IpPacket?:
    if (version backing) == IPV4-VERSION_:
      return IpV4Packet.create backing
    return null

  handle socket -> none:
    print backing.size
    print "Version: $version"
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
  protocol -> int:
    return protocol backing

  static protocol backing/ByteArray -> int:
    return backing[9]

  static create backing/ByteArray -> IpV4Packet?:
    assert: (IpPacket.version backing) == IPV4-VERSION_
    protocol := protocol backing
    if protocol == ICMP-PROTOCOL_:
      return IcmpPacket.create backing
    if protocol == TCP-PROTOCOL_:
      return TcpPacket backing
    if protocol == UDP-PROTOCOL_:
      return UdpPacket backing
    return null

  constructor.from-subclass backing/ByteArray:
    super.from-subclass backing

  source-ip -> IpAddress:
    return IpAddress backing[12..16]

  destination-ip -> IpAddress:
    return IpAddress backing[16..20]

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
    print "Got ping response from $source-ip"

class DestinationUnreachablePacket extends IcmpPacket:
  constructor backing/ByteArray:
    super.from-subclass backing

  handle socket:
    print "Got destination unreachable from $source-ip"

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

class TunHost:
  interfaces_/List := []
  tun-socket_/TunSocket

  constructor .tun-socket_:

  /**
  Sets the local port of a UDP socket.
  If the $port is zero then a free port is picked.
  If the address is null then the socket is bound on the first interface.
  */
  udp-bind socket/TunUdpSocket --port/int=0 --address/IpAddress?=null:
    if interfaces_.size == 0:
      throw "No interfaces"
    inter-face := null
    if not address:
      inter-face = interfaces_[0]
    else:
      interfaces_.do:
        if it.address == address:
          inter-face = it
    if not inter-face:
      throw "No interface with address $address"
    inter-face.udp-bind socket port

class TunInterface:
  address/IpAddress
  mask/IpAddress

  constructor .address --mask/IpAddress?=null --mask-bits/int?=null:
    if mask:
      if mask-bits:
        throw "Cannot specify both mask and mask-bits"
      this.mask = mask
    if mask-bits:
      if not 1 <= mask-bits <= 32:
        throw "Invalid mask-bits"
      bits := (0xffff_ffff_0000_0000 >> mask-bits) & 0xffff_ffff
      this.mask = IpAddress #[
          bits >> 24,
          (bits >> 16) & 0xff,
          (bits >> 8) & 0xff,
          bits & 0xff
      ]
    else:
      first := address.raw[0]
      if first == 192:
        this.mask = IpAddress #[255, 255, 255, 0]
      else if first == 10:
        this.mask = IpAddress #[255, 0, 0, 0]
      else if first == 172:
        this.mask = IpAddress #[255, 240, 0, 0]
      else:
        throw "No mask given"

  // Sets the local port of a UDP socket.
  // If the $port is zero then a free port is picked.
  udp-bind socket/TunUdpSocket --port/int --address/IpAddress?=null:
    if socket.port != 0:
      throw "Socket already bound"
    if port == 0:
      start := (random 16384) + 49152
      16384.repeat:
        possible-port := 49152 + ((start + it) & 16383)
        // Other socket may be null due to weakness.
        other-socket := unconnected-udp-sockets_.get possible-port
        if not other-socket:
          unconnected-udp-sockets_[possible-port] = socket
          socket.port = possible-port
          return
      throw "No more free dynamic ports"
    // An entry may be null due to weakness.
    if unconnected-udp-sockets_.get port:
      throw "Port already bound"
    unconnected-udp-sockets_[port] = socket
    socket.port = port

  udp-connect socket/TunUdpSocket --port/int?=0 --remote-address/IpAddress --remote-port/int:
    if port == 0:
      port = socket.port
    if port == 0:
      udp-bind socket --port=port
    triple := Triple_ port remote-address --remote-port=remote-port
    other-socket := connected-udp-sockets_.get triple
    if other-socket:
      throw "A connected socket already has this address and port"
    connected-udp-sockets_[triple] = socket
    socket.remote-port = remote-port


  // These maps are weak so that if the socket is lost it is removed from the
  // maps.
  // A map from the local port number to the socket.
  unconnected-udp-sockets_/Map := Map.weak
  // A map from triples (local port, remote address, remote port) to the
  // sockets.
  connected-udp-sockets_/Map := Map.weak

// A triple of (local port, remote address, remote port).
class Triple_:
  local-port/int
  remote-address/IpAddress
  remote-port/int

  constructor .local-port .remote-address --.remote-port:

  hash-code -> int:
    return local-port * 13 + remote-address.raw[3] * 247 + remote-port

  operator == other:
    if other is not Triple_: return false
    if other.local-port != local-port: return false
    if other.remote-address != remote-address: return false
    if other.remote-port != remote-port: return false
    return true

class TunUdpSocket:
  // Can be in several states:
  // Unbound:
  //   The initial state, before bind or write is called.
  // Bound (Unconnected):
  //   The socket is bound (has local IP and port), but not connected
  //   (no remote IP and port).  It can receive any packets sent to the
  //   local address.  It can send to any address using send-to.
  //   Two different unconnected sockets cannot be bound to the same port.
  // Connected:
  //   The socket is bound and connected so it has the full 4-tuple of IP and
  //   ports. It can only receive from the remove server and it sends by
  //   default (with write) to the remote server.  Connecting an unbound socket
  //   will cause it to be bound as a side effect.

  // The local port.  If the socket is unbound then this is zero.
  port/int := 0

  // The remote port.  If the socket is not connected then this is zero.
  remote-port/int := 0

  // The remote address.  If the socket is not connected then this is null.
  remote-address/IpAddress? := null

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
