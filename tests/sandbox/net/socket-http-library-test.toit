// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Variant S of the sandbox network: the unchanged HTTP client of the http
  package runs inside a sandbox on sockets of the sandbox socket service.
  Plain HTTP over a service TCP socket; HTTPS over a service TLS socket,
  with the http library doing only HTTP on top (its URLs are http URLs
  with the TLS port).
*/

import expect show *
import http
import net.sandbox
import net.x509
import tls
import .net-util
import .test-certificate

main args:
  run-test args --roles={
    "plain": :: | arguments/Map |
      port := arguments["port"]
      client := http.Client sandbox.open
      response := client.get "127.0.0.1" --port=port "/small"
      expect-equals 200 response.status-code
      expect-equals "hello" response.body.read-all.to-string
      // The client keeps the connection for the next requests.
      response = client.post (pattern 10_000) --uri="http://127.0.0.1:$port/echo"
      expect-equals (pattern 10_000) response.body.read-all
      response = client.get --uri="http://127.0.0.1:$port/big?n=200000"
      expect-equals (pattern 200_000) response.body.read-all
      response = client.get --uri="http://127.0.0.1:$port/chunked?n=30000"
      expect-equals (pattern 30_000) response.body.read-all
      client.close,

    "tls": :: | arguments/Map |
      port := arguments["port"]
      network := sandbox.open
      network.add-root-certificate TEST-CERTIFICATE
      client := http.Client network.with-tls
      response := client.get --uri="http://localhost:$port/small"
      expect-equals 200 response.status-code
      expect-equals "hello" response.body.read-all.to-string
      response = client.get --uri="http://localhost:$port/big?n=100000"
      expect-equals (pattern 100_000) response.body.read-all
      client.close,

    "https-in-sandbox": :: | arguments/Map |
      // The http library's own TLS needs primitives a sandbox can't call.
      client := http.Client sandbox.open
      expect-equals "PRIMITIVE_LOOKUP_FAILED"
          catch: client.get --uri="https://localhost:$arguments["port"]/small",
  }:
    server := HttpServer
    expect-sandbox "plain" {"port": server.port}
        --network={"allow": ["127.0.0.1:$server.port"], "bytes-per-second": 1024 * 1024}
    certificate := tls.Certificate (x509.Certificate.parse TEST-CERTIFICATE) TEST-KEY
    secure := HttpServer --certificate=certificate
    allow := ["localhost:$secure.port", "127.0.0.1:$secure.port"]
    expect-sandbox "tls" {"port": secure.port}
        --network={"allow": allow, "bytes-per-second": 1024 * 1024}
    expect-sandbox "https-in-sandbox" {"port": secure.port}
        --network={"allow": allow}
    server.close
    secure.close
