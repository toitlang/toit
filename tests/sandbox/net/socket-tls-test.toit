// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Variant S of the sandbox network: TLS run by the system process. The
  driver runs a local TLS echo server with a self-signed certificate for
  "localhost" (test-root.pem), which the system process trusts on the host
  through TOIT_SANDBOX_NETWORK_ROOTS (set by the CMake test). The sandbox
  can't skip the verification: connecting with a name the certificate
  doesn't cover fails.
*/

import expect show *
import net
import net.x509
import net.sandbox
import net.tcp
import tls
import .net-util
import .test-certificate

main args:
  run-test args --roles={
    "tls": :: | arguments/Map |
      base := sandbox.open
      // The provider has no roots: the sandbox brings the one it trusts.
      base.add-root-certificate TEST-CERTIFICATE
      network := base.with-tls
      socket := network.tcp-connect "localhost" arguments["port"]
      socket.out.write "secret"
      expect-equals "secret" socket.in.read.to-string
      socket.out.write (pattern 20_000)
      socket.out.close
      expect-equals (pattern 20_000) socket.in.read-all
      socket.close,

    "wrong-name": :: | arguments/Map |
      base := sandbox.open
      base.add-root-certificate TEST-CERTIFICATE
      network := base.with-tls
      expect-equals "TLS_FAILED" (catch: network.tcp-connect "127.0.0.1" arguments["port"]),
  }:
    certificate := tls.Certificate (x509.Certificate.parse TEST-CERTIFICATE) TEST-KEY
    network := net.open
    server-socket := network.tcp-listen 0
    port := server-socket.local-address.port
    server := task::
      while true:
        client := server-socket.accept
        if not client: continue
        task::
          catch:
            secure := tls.Socket.server client --certificate=certificate
            while data := secure.in.read: secure.out.write data
            secure.out.close
          client.close

    expect-sandbox "tls" {"port": port}
        --network={"allow": ["localhost:$port", "127.0.0.1:$port"]}
    expect-sandbox "wrong-name" {"port": port}
        --network={"allow": ["127.0.0.1:$port"]}
    server.cancel
    server-socket.close
    network.close
