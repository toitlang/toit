import host.os
import net
import net.tcp

TEST-PORT-ENV ::= "TEST_PORT"
TEST-INTERVAL-MS ::= 20

main:
  network := net.open
  port := int.parse os.env[TEST-PORT-ENV]
  // On Windows, the server.local-address doesn't have a valid IP address,
  // so we just hard-code it to 127.0.0.1.
  ip-address := net.IpAddress.parse "127.0.0.1"
  address := net.SocketAddress ip-address port
  client := network.tcp-connect address
  while true:
    client.out.write "Hello, world!\n"
    client.out.flush
    sleep --ms=TEST-INTERVAL-MS
