// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Variant H of the sandbox network: HTTP requests made by the system
  process for a sandbox, with request and response bodies streamed in
  chunks, against a local HTTP and HTTPS server.
*/

import expect show *
import io
import net.sandbox-http
import net.x509
import tls
import .net-util
import .test-certificate

main args:
  run-test args --roles={
    "requests": :: | arguments/Map |
      base := "http://127.0.0.1:$arguments["port"]"
      client := sandbox-http.open
      response := client.get "$base/small"
      expect-equals 200 response.status-code
      expect-equals "hello" response.body.read-all.to-string
      response.close
      // A body with a known length.
      response = client.post "$base/echo" (pattern 10_000) --content-type="application/octet-stream"
      expect-equals (pattern 10_000) response.body.read-all
      response.close
      // A body from a reader is sent chunked.
      response = client.request "POST" "$base/count" --body=(io.Reader (pattern 50_000))
      expect-equals "50000" response.body.read-all.to-string
      response.close
      // Request headers reach the server.
      response = client.get "$base/headers" --headers={"X-Test": "sandboxed"}
      expect-equals "sandboxed" response.body.read-all.to-string
      response.close
      // A chunked response.
      response = client.get "$base/chunked?n=30000"
      expect-equals (pattern 30_000) response.body.read-all
      response.close
      // Redirects are not followed: the client sees the 3xx response.
      response = client.get "$base/redirect"
      expect-equals 302 response.status-code
      expect-equals "/small" response.headers["location"]
      response.close,

    "bulk": :: | arguments/Map |
      base := "http://127.0.0.1:$arguments["port"]"
      client := sandbox-http.open
      start := Time.monotonic-us
      response := client.get "$base/big?n=$(1024 * 1024)"
      received := 0
      expected := pattern (1024 * 1024)
      while chunk := response.body.read:
        expect-equals expected[received..received + chunk.size] chunk
        received += chunk.size
      expect-equals 1024 * 1024 received
      response.close
      print "1 MB download: $((Time.monotonic-us - start) / 1000) ms"
      start = Time.monotonic-us
      response = client.post "$base/count" (pattern 256 * 1024)
      expect-equals "$(256 * 1024)" response.body.read-all.to-string
      response.close
      print "256 KB upload: $((Time.monotonic-us - start) / 1000) ms",

    "https": :: | arguments/Map |
      client := sandbox-http.open
      client.add-root-certificate TEST-CERTIFICATE
      response := client.get "https://localhost:$arguments["port"]/small"
      expect-equals 200 response.status-code
      expect-equals "hello" response.body.read-all.to-string
      response.close
      // The certificate is for "localhost".
      expect-equals "TLS_FAILED"
          catch: client.get "https://127.0.0.1:$arguments["port"]/small",
  }:
    server := HttpServer
    allow := ["127.0.0.1:$server.port"]
    expect-sandbox "requests" {"port": server.port} --network={"allow": allow}
    expect-sandbox "bulk" {"port": server.port}
        --network={"allow": allow, "bytes-per-second": 1024 * 1024, "response-bytes": 2 * 1024 * 1024}
    certificate := tls.Certificate (x509.Certificate.parse TEST-CERTIFICATE) TEST-KEY
    secure := HttpServer --certificate=certificate
    expect-sandbox "https" {"port": secure.port}
        --network={"allow": ["localhost:$secure.port", "127.0.0.1:$secure.port"]}
    server.close
    secure.close
