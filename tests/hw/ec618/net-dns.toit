// Tests DNS resolution over cellular on EC618.

import net

main:
  print "Opening network..."
  network := net.open
  try:
    print "Network address: $network.address"

    HOSTS ::= [
      "google.com",
      "example.com",
      "toitlang.org",
    ]

    HOSTS.do: | host |
      print "Resolving $host..."
      addresses := network.resolve host
      print "  -> $addresses"

    print "DNS TEST PASSED"
  finally:
    network.close
