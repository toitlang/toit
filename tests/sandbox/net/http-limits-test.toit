// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Variant H of the sandbox network: what the policy and the service refuse
  (destinations, path prefixes, path tricks, headers the service sets), the
  response size limit, the request timeout and the connection limit.
*/

import expect show *
import net.sandbox-http
import system.api.sandbox-network show SandboxHttpService
import .net-util
import ..sandbox show provider-ids open-without-discovery

main args:
  run-test args --roles={
    "denied": :: | arguments/Map |
      port := arguments["port"]
      client := sandbox-http.open
      // Only paths under /api/ are allowed.
      response := client.get "http://127.0.0.1:$port/api/x"
      expect-equals "/api/x" response.body.read-all.to-string
      response.close
      expect-equals "NETWORK_DENIED" (catch: client.get "http://127.0.0.1:$port/admin")
      expect-equals "NETWORK_DENIED" (catch: client.get "http://127.0.0.1:$port/api/../admin")
      expect-equals "NETWORK_DENIED" (catch: client.get "http://127.0.0.1:$port/api/%2e%2e/admin")
      expect-equals "NETWORK_DENIED" (catch: client.get "http://127.0.0.1:$(port + 1)/api/x")
      expect-equals "NETWORK_DENIED" (catch: client.get "http://localhost:$port/api/x")
      // The policy doesn't restrict the scheme: TLS to the plain server fails.
      expect-equals "TLS_FAILED" (catch: client.get "https://127.0.0.1:$port/api/x")
      expect-equals "INVALID_ARGUMENT" (catch: client.get "ftp://127.0.0.1:$port/api/x")
      expect-equals "INVALID_ARGUMENT" (catch: client.get "http://user@127.0.0.1:$port/api/x")
      // Headers that the service sets or that change the framing.
      ["Host", "content-length", "Transfer-Encoding", "Connection"].do: | name |
        expect-equals "INVALID_ARGUMENT"
            catch: client.get "http://127.0.0.1:$port/api/x" --headers={name: "1"}
      expect-equals "INVALID_ARGUMENT"
          catch: client.get "http://127.0.0.1:$port/api/x" --headers={"X-Test": "a\r\nHost: evil"}
      expect-equals "INVALID_ARGUMENT"
          catch: client.request "GE T" "http://127.0.0.1:$port/api/x",

    "too-large": :: | arguments/Map |
      base := "http://127.0.0.1:$arguments["port"]"
      client := sandbox-http.open
      // With a content length, the response is refused before its body.
      expect-equals "RESPONSE_TOO_LARGE" (catch: (client.get "$base/big?n=5000").body.read-all)
      // A chunked response fails when it gets too large.
      expect-equals "RESPONSE_TOO_LARGE" (catch: (client.get "$base/chunked?n=5000").body.read-all)
      response := client.get "$base/big?n=1000"
      expect-equals 1000 response.body.read-all.size
      response.close,

    "timeout": :: | arguments/Map |
      client := sandbox-http.open
      start := Time.monotonic-us
      expect-equals "TIMEOUT" (catch: client.get "http://127.0.0.1:$arguments["port"]/slow")
      elapsed-ms := (Time.monotonic-us - start) / 1000
      expect 900 <= elapsed-ms < 2_900,

    "connections": :: | arguments/Map |
      base := "http://127.0.0.1:$arguments["port"]"
      client := sandbox-http.open
      // An open response holds its connection.
      a := client.get "$base/small"
      expect-equals "NETWORK_QUOTA_EXCEEDED" (catch: client.get "$base/small")
      a.close
      b := client.get "$base/small"
      expect-equals "hello" b.body.read-all.to-string
      b.close,

    "not-listed": :: | arguments/Map |
      expect-equals "Sandbox HTTP unavailable" (catch: sandbox-http.open)
      ids := arguments["ids"]
      expect-equals "PERMISSION_DENIED"
          catch: open-without-discovery ids[0] ids[1] SandboxHttpService.SELECTOR,
  }:
    server := HttpServer
    port := server.port
    expect-sandbox "denied" {"port": port}
        --network={"allow": ["127.0.0.1:$port/api/"]}
    expect-sandbox "too-large" {"port": port}
        --network={"allow": ["127.0.0.1:$port"], "response-bytes": 2000}
    expect-sandbox "timeout" {"port": port}
        --network={"allow": ["127.0.0.1:$port"], "timeout-ms": 1000}
    expect-sandbox "connections" {"port": port}
        --network={"allow": ["127.0.0.1:$port"], "connections": 1}
    expect-sandbox "not-listed" {"ids": provider-ids HTTP-SERVICE} --services=[]
    server.close
