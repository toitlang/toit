
import net
import net.udp
import net.modules.udp as impl
import expect show *

MULTICAST-ADDRESS := net.IpAddress.parse "239.1.2.3"
PORT := 12345

main:
  network := net.open
  
  // Create a listening socket for multicast.
  // We use the implementation class directly for the multicast constructor.
  socket := impl.Socket.multicast network
      MULTICAST-ADDRESS
      PORT
      --loopback
      --ttl=1
      --reuse-address
      --reuse-port

  print "Socket created and bound to $PORT, joined $MULTICAST-ADDRESS"

  // Create a sender socket (normal socket).
  sender := network.udp-open

  msg := "Hello Multicast"
  datagram := udp.Datagram
      msg.to-byte-array
      net.SocketAddress MULTICAST-ADDRESS PORT

  print "Sending message: $msg"
  sender.send datagram

  print "Waiting to receive..."
  received := socket.receive
  print "Received: $(received.data.to-string)"
  
  expect-equals msg received.data.to-string
  
  // received.address is the SENDER address.
  print "Received from port: $(received.address.port)"

  socket.close
  sender.close
