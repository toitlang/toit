import net
import net.modules.udp as udp_impl
import expect show *

main:
  network := net.open
  try:
    test-multicast-cow network
  finally:
    network.close

test-multicast-cow network/net.Client:
  // Use a COW byte array (literal) for the multicast group
  group := #[224, 0, 0, 251]
  socket := udp_impl.Socket.multicast network
      --port=0
  socket.multicast-add-membership (net.IpAddress group)

  print "Successfully created multicast socket with COW address"
  socket.close
