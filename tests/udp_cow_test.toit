import net
import net.modules.udp as udp_impl
import expect show *

main:
  test-multicast-cow

test-multicast-cow:
  network := net.open
  // Use a COW byte array (literal) for the multicast group
  group := #[224, 0, 0, 251]
  port := 5353

  socket := udp_impl.Socket.multicast network
      (net.IpAddress group)
      port
  
  print "Successfully created multicast socket with COW address"
  socket.close
