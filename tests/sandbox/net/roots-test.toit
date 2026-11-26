// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Root certificates brought by the sandboxes: the provider has none of its
  own. Two sandboxes that trust different roots connect to the same TLS
  server at the same time, and only the one trusting its root succeeds
  (one client's roots never decide another's verification). Identical roots
  of several clients are stored once and freed with the last client. The
  per-client bounds, root selection by id, uploads in chunks, and the
  policy's pins (the owner fixes the server's root, the sandbox still
  brings the certificate) and require-pins.
*/

import crypto.sha256
import encoding.base64
import expect show *
import net
import net.sandbox
import net.sandbox-http
import net.x509
import tls
import system.api.sandbox-network show SandboxNetworkClient SandboxSocketService
import .net-util
import .test-certificate

main args:
  run-test args --roles={
    "trust": :: | arguments/Map |
      network := sandbox.open
      network.add-root-certificate (arguments["root"] == "test" ? TEST-CERTIFICATE : OTHER-CERTIFICATE)
      // Both sandboxes run at the same time; wait until both registered.
      sleep --ms=300
      exception := catch:
        socket := network.with-tls.tcp-connect "localhost" arguments["port"]
        socket.out.write "x"
        expect-equals "x" socket.in.read.to-string
        socket.close
      expect-equals arguments["expected"] exception,

    "hold": :: | arguments/Map |
      network := sandbox.open
      arguments["roots"].do: | name |
        network.add-root-certificate (name == "test" ? TEST-CERTIFICATE : OTHER-CERTIFICATE)
      while true: sleep --ms=100,

    "select": :: | arguments/Map |
      port := arguments["port"]
      network := sandbox.open
      test := network.add-root-certificate TEST-CERTIFICATE
      other := network.add-root-certificate OTHER-CERTIFICATE
      expect-equals "TLS_FAILED" (catch: (network.with-tls --roots=[other]).tcp-connect "localhost" port)
      ((network.with-tls --roots=[test]).tcp-connect "localhost" port).close
      (network.with-tls.tcp-connect "localhost" port).close
      expect-equals "INVALID_ARGUMENT" (catch: (network.with-tls --roots=[17]).tcp-connect "localhost" port)
      // Without roots, TLS fails: the provider has none.
      expect-equals "TLS_FAILED" (catch: sandbox.open.with-tls.tcp-connect "localhost" port)
      // Variant H takes the session's roots as well.
      client := sandbox-http.open
      expect-equals "TLS_FAILED" (catch: client.get "https://localhost:$arguments["http-port"]/small")
      client.add-root-certificate arguments["der"]  // DER works too.
      response := client.get "https://localhost:$arguments["http-port"]/small"
      expect-equals "hello" response.body.read-all.to-string,

    "limits": :: | arguments/Map |
      network := sandbox.open
      // A root larger than a chunk is uploaded in pieces.
      network.add-root-certificate (ByteArray 6000: it)
      network.add-root-certificate (ByteArray 1000)
      expect-equals "NETWORK_QUOTA_EXCEEDED" (catch: network.add-root-certificate (ByteArray 2000))
      network.add-root-certificate (ByteArray 100)
      network.add-root-certificate (ByteArray 100)
      expect-equals "NETWORK_QUOTA_EXCEEDED" (catch: network.add-root-certificate (ByteArray 10))
      // A new session starts empty.
      sandbox.open.add-root-certificate TEST-CERTIFICATE,

    "pinned": :: | arguments/Map |
      network := sandbox.open
      network.add-root-certificate TEST-CERTIFICATE
      network.add-root-certificate OTHER-CERTIFICATE
      exception := catch: (network.with-tls.tcp-connect "localhost" arguments["port"]).close
      expect-equals arguments["expected"] exception
      // Plain TCP isn't affected by pins.
      (network.tcp-connect "localhost" arguments["port"]).close,
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
    http-server := HttpServer --certificate=certificate
    allow := ["localhost:$port", "127.0.0.1:$port", "localhost:$http-server.port", "127.0.0.1:$http-server.port"]

    // Two sandboxes, two roots, one server, at the same time.
    a := start-sandbox "trust" {"port": port, "root": "test", "expected": null} --network=allow
    b := start-sandbox "trust" {"port": port, "root": "other", "expected": "TLS_FAILED"} --network=allow
    expect-equals 0 a.wait
    expect-equals 0 b.wait

    // Identical roots are stored once, until their last client goes.
    stats := SandboxNetworkClient SandboxSocketService.SELECTOR
    stats.open
    expect-equals 0 stats.stats[0]
    x := start-sandbox "hold" {"roots": ["test", "other"]} --network=allow
    wait-for-roots stats 2
    y := start-sandbox "hold" {"roots": ["test"]} --network=allow
    sleep --ms=500
    expect-equals 2 stats.stats[0]
    expect-equals (x509-der_ TEST-CERTIFICATE).size + (x509-der_ OTHER-CERTIFICATE).size stats.stats[1]
    x.stop
    wait-for-roots stats 1
    y.stop
    wait-for-roots stats 0
    stats.close

    expect-sandbox "select" {"port": port, "http-port": http-server.port, "der": x509-der_ TEST-CERTIFICATE}
        --network=allow
    expect-sandbox "limits" --network=allow

    // Pins: the owner fixes the root, the sandbox brings it.
    test-pin := hex_ (sha256.sha256 (x509-der_ TEST-CERTIFICATE))
    other-pin := hex_ (sha256.sha256 (x509-der_ OTHER-CERTIFICATE))
    expect-sandbox "pinned" {"port": port, "expected": null}
        --network=["localhost:$port#$test-pin", "127.0.0.1:$port"]
    expect-sandbox "pinned" {"port": port, "expected": "TLS_FAILED"}
        --network=["localhost:$port#$other-pin", "127.0.0.1:$port"]
    expect-sandbox "pinned" {"port": port, "expected": "NETWORK_DENIED"}
        --network={"allow": ["localhost:$port", "127.0.0.1:$port"], "require-pins": true}
    expect-sandbox "pinned" {"port": port, "expected": null}
        --network={"allow": ["localhost:$port#$test-pin", "127.0.0.1:$port"], "require-pins": true}

    server.cancel
    server-socket.close
    network.close
    http-server.close

wait-for-roots client/SandboxNetworkClient count/int -> none:
  with-timeout --ms=5_000:
    while client.stats[0] != count: sleep --ms=20

x509-der_ pem/string -> ByteArray:
  lines := (pem.trim.split "\n").filter: not it.starts-with "-----"
  return base64.decode (lines.join "")

hex_ bytes/ByteArray -> string:
  return (List bytes.size: "$(%02x bytes[it])").join ""
