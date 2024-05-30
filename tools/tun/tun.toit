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
    return backing[0] >> 4

  static version backing/ByteArray -> int:
    return backing[0] >> 4

  version= value/int -> none:
    backing[0] = (backing[0] & 0x0F) | (value << 4)

  header-length -> int:
    return (backing[0] & 0x0F) << 2

  header-length= value/int -> none:
    if (not value <= 20 <= 60) or value & 3 != 0:
      throw "Invalid header length"
    backing[0] = (backing[0] & 0xF0) | (value >> 2)

  length -> int:
    return BIG-ENDIAN.uint16 backing 2

  length= value/int -> none:
    BIG-ENDIAN.put-uint16 backing 2 value
    assert: backing.size == value

  ttl -> int:
    return backing[8]

  ttl= value/int -> none:
    backing[8] = value

  static create backing/ByteArray -> IpPacket?:
    if (version backing) == IPV4-VERSION_:
      return IpV4Packet.create backing
    return null

  handle network-interface/NetworkInterface -> none:
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
  identification -> int:
    return BIG-ENDIAN.uint16 backing 4

  identification= value/int:
    BIG-ENDIAN.put-uint16 backing 4 value

  protocol -> int:
    return backing[9]

  protocol= value/int -> none:
    backing[9] = value

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

  source-ip= value/IpAddress -> none:
    backing.replace 12 value.raw

  destination-ip -> IpAddress:
    return IpAddress backing[16..20]

  destination-ip= value/IpAddress -> none:
    backing.replace 16 value.raw

class IcmpPacket extends IpV4Packet:
  static icmp-type backing/ByteArray -> int:
    return backing[20]

  icmp-type -> int:
    return backing[20]

  ttl -> int:
    return backing[8]

  static create backing/ByteArray -> IcmpPacket?:
    type := icmp-type backing
    if type == ICMP-ECHO-REQUEST_:
      return PingRequestPacket backing
    if type == ICMP-ECHO-RESPONSE_:
      return PingResponsePacket backing
    if type == ICMP-DESTINATION-UNREACHABLE_:
      return DestinationUnreachablePacket backing
    print "type = $type"
    unreachable

  constructor.from-subclass backing/ByteArray:
    super.from-subclass backing

class PingRequestPacket extends IcmpPacket:
  constructor backing/ByteArray:
    super.from-subclass backing

  response -> PingResponsePacket?:
    response-backing := backing.copy
    response-backing[20] = ICMP-ECHO-RESPONSE_
    // Reverse the source and destination addresses.
    response-backing.replace 12 backing 16 20
    response-backing.replace 16 backing 12 16
    // Decrement the TTL.
    if ttl == 0: return null
    response-backing[8] = ttl - 1
    // Calculate the checksum.
    return PingResponsePacket response-backing

  handle network-interface/NetworkInterface -> none:
    response := response
    if response:
      network-interface.send response

class PingResponsePacket extends IcmpPacket:
  constructor backing/ByteArray:
    super.from-subclass backing

  handle network-interface/NetworkInterface -> none:
    print "Got ping response from $source-ip"

class DestinationUnreachablePacket extends IcmpPacket:
  constructor backing/ByteArray:
    super.from-subclass backing

  handle network-interface/NetworkInterface -> none:
    print "Got destination unreachable from $source-ip"

class UdpPacket extends IpV4Packet:
  constructor backing/ByteArray:
    super.from-subclass backing

  source-port -> int:
    return BIG-ENDIAN.uint16 backing 20

  source-port= value/int:
    BIG-ENDIAN.put-uint16 backing 20 value

  destination-port -> int:
    return BIG-ENDIAN.uint16 backing 22

  destination-port= value/int:
    BIG-ENDIAN.put-uint16 backing 22 value

  udp-length -> int:
    return BIG-ENDIAN.uint16 backing 24

  udp-length= value/int:
    BIG-ENDIAN.put-uint16 backing 24 value

class TcpPacket extends IpV4Packet:
  constructor backing/ByteArray:
    super.from-subclass backing

main:
  network-interface := TunInterface TunSocket
      IpAddress #[10, 0, 0, 2]

  IpHost.interfaces.add network-interface

  task --background:: network-interface.run

  socket := TunUdpSocket

  IpHost.udp-bind socket

  socket.connect
      --remote-address=IpAddress #[8, 8, 8, 8]
      --remote-port=53

  sleep --ms=10_000

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

class IpHost:
  static interfaces/List := []

  /**
  Sets the local port of a UDP socket.
  If the $port is zero then a free port is picked.
  If the address is null then the socket is bound on the first interface.
  */
  static udp-bind socket/TunUdpSocket --port/int=0 --address/IpAddress?=null:
    network-interface := find-interface_ address
    network-interface.udp-bind socket --port=port

  static find-interface_ address/IpAddress? -> NetworkInterface:
    if not address:
      if interfaces.size == 0:
        throw "No interfaces"
      return interfaces[0]
    interfaces.do:
      if it.address == address:
        return it
    throw "No interface with address $address."

interface NetworkInterface:
  /// An endless loop that reads incoming packets from the network interface.
  run -> none
  udp-bind socket/TunUdpSocket --port/int=0
  udp-connect socket/TunUdpSocket --port/int?=0 --remote-address/IpAddress --remote-port/int
  send packet/IpPacket
  address -> IpAddress

class TunInterface implements NetworkInterface:
  tun-socket_/TunSocket
  address/IpAddress
  mask/IpAddress

  send packet/IpPacket -> none:
    tun-socket_.send packet.backing

  /// An endless loop that takes packets from the socket and processes them.
  run -> none:
    while true:
      raw := tun-socket_.receive
      if not raw: return
      if raw.size == 0: continue
      packet := IpPacket.create raw
      if packet == null or not packet is IpV4Packet:
        print "Dropping non-IPv4 packet"
        continue
      ipv4-packet := packet as IpV4Packet
      if ipv4-packet.destination-ip != address:
        print "Dropping packet to $ipv4-packet.destination-ip"
        continue
      packet.handle this

  constructor .tun-socket_ .address --mask/IpAddress?=null --mask-bits/int?=null:
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
  udp-bind socket/TunUdpSocket --port/int=0:
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
          socket.network-interface = this
          return
      throw "No more free dynamic ports"
    // An entry may be null due to weakness.
    if unconnected-udp-sockets_.get port:
      throw "Port already bound"
    unconnected-udp-sockets_[port] = socket
    socket.port = port
    socket.network-interface = this

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

  // The local interface.  If the socket is unbound then this is null.
  network-interface/NetworkInterface? := null

  // The local port.  If the socket is unbound then this is zero.
  port/int := 0

  // The remote port.  If the socket is not connected then this is zero.
  remote-port/int := 0

  // The remote address.  If the socket is not connected then this is null.
  remote-address/IpAddress? := null

  packet-identification := random 0x10000

  connect --remote-address/IpAddress --remote-port/int:
    if not network-interface:
      IpHost.udp-bind this
    network-interface.udp-connect this --remote-address=remote-address --remote-port=remote-port

  write data/io.Data -> none:
    send data

  send data/io.Data -> none:
    if not network-interface:
      IpHost.udp-bind this
    if not remote-address:
      throw "Not connected"
    send-to data --address=remote-address --port=remote-port

  send-to data/io.Data --address/IpAddress --port/int -> none:
    raw := ByteArray data.byte-size + 28
    raw.replace 28 data
    packet := UdpPacket raw
    packet.source-ip = network-interface.address
    packet.destination-ip = address
    packet.source-port = this.port
    packet.destination-port = port
    packet.udp-length = 8 + data.byte-size
    packet.version = IPV4-VERSION_
    packet.header-length = 20
    packet.length = raw.size
    // The identification field is supposed to be unique for the triple of
    // protocol, remote IP, local IP.  TODO: Here we have it on the UDP socket
    // for simplicity.  Some cell phones just set it to zero.  See also RFC
    // 6864.
    packet.identification = packet-identification
    packet.ttl = 64
    packet.protocol = UDP-PROTOCOL_
    packet-identification = (packet-identification + 1) & 0xffff

    if not network-interface: network-interface = IpHost.find-interface_ address
    network-interface.send packet

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
