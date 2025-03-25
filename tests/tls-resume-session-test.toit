// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import certificate_roots
import encoding.tison
import expect show *
import net
import net.modules.dns
import net.modules.tcp
import net.x509 as net
import tls

network := net.open

main:
  certificate-roots.install-common-trusted-roots

  test-site-with-one-retry "cloudflare.com"
  test-site-with-one-retry "adafruit.com"
  test-site-with-one-retry "ft.dk"

  // These two are too flaky.  Often the first reconnect succeeds, but the
  // second one fails.
  if false:
    test-site-with-one-retry "amazon.com"
    test-site-with-one-retry "app.supabase.com" --no-read-data

test-site-with-one-retry host/string --read-data/bool=true -> none:
  catch --trace:
    with-timeout --ms=10_000:
      test-site host --read-data=read-data
    return
  with-timeout --ms=10_000:
    test-site host --read-data=read-data

test-site host/string --read-data/bool=true -> none:
  port := 443

  saved-session := null

  3.repeat: | iteration |
    if iteration != 0:
      // Big sites have a centralized store for session data.  If you connect
      // too fast the session hasn't reached the store and resume fails.
      sleep --ms=200

    raw := tcp.TcpSocket network
    raw.connect host port
    socket/tls.Socket := tls.Socket.client raw
      // Install the roots needed.
      --server-name=host

    resume-expectation := saved-session != null

    method := "full MbedTLS handshake"
    if saved-session:
      socket.session-state = saved-session
      decoded := tison.decode saved-session
      if decoded[0].size != 0: method = "resumed with ID"
      if decoded[1].size != 0: method = "resumed with ticket"

    expect
        not socket.session-resumed  // Not connected yet.

    duration := Duration.of:
      socket.handshake

    expect-equals resume-expectation socket.session-resumed
    if resume-expectation:
      expect-equals tls.SESSION-MODE-TOIT socket.session-mode

    saved-session = socket.session-state
    expect: saved-session != null

    suite := -1
    got-id := false
    got-ticket := false
    if saved-session:
      decoded := tison.decode saved-session
      if decoded[0].size != 0: got-id = true
      if decoded[1].size != 0: got-ticket = true
      suite = decoded[3]

    suite-name := SUITE-MAP.get suite --if-absent=: "suite 0x$(%04x suite)"

    print "Handshake complete ($(%22s method), $suite-name) to $(%16s host) in $(%4d duration.in-ms) ms$(got-id ? " (Got session ID)" : "")$(got-ticket ? " (Got session ticket)" : "")"

    expect: got-id or got-ticket

    writer := socket.out
    reader := socket.in
    if read-data:
      writer.write "GET / HTTP/1.1\r\n"
      writer.write "Host: $host\r\n"
      writer.write "\r\n"

      while data := reader.read:
        str := data.to-string
        if str.contains "301 Moved Permanently":
          break

    socket.close

    expect-equals tls.SESSION-MODE-CLOSED socket.session-mode

SUITE-MAP ::= {
    0x0000: "NULL_WITH_NULL_NULL",
    0x0001: "RSA_WITH_NULL_MD5",
    0x0002: "RSA_WITH_NULL_SHA",
    0x0003: "RSA_EXPORT_WITH_RC4_40_MD5",
    0x0004: "RSA_WITH_RC4_128_MD5",
    0x0005: "RSA_WITH_RC4_128_SHA",
    0x0006: "RSA_EXPORT_WITH_RC2_CBC_40_MD5",
    0x0009: "RSA_WITH_DES_CBC_SHA",
    0x000a: "RSA_WITH_3DES_EDE_CBC_SHA",
    0x000c: "DH_DSS_WITH_DES_CBC_SHA",
    0x000d: "DH_DSS_WITH_3DES_EDE_CBC_SHA",
    0x000f: "DH_RSA_WITH_DES_CBC_SHA",
    0x0010: "DH_RSA_WITH_3DES_EDE_CBC_SHA",
    0x0012: "DHE_DSS_WITH_DES_CBC_SHA",
    0x0013: "DHE_DSS_WITH_3DES_EDE_CBC_SHA",
    0x0015: "DHE_RSA_WITH_DES_CBC_SHA",
    0x0016: "DHE_RSA_WITH_3DES_EDE_CBC_SHA",
    0x002f: "RSA_WITH_AES_128_CBC_SHA",
    0x0030: "DH_DSS_WITH_AES_128_CBC_SHA",
    0x0031: "DH_RSA_WITH_AES_128_CBC_SHA",
    0x0032: "DHE_DSS_WITH_AES_128_CBC_SHA",
    0x0033: "DHE_RSA_WITH_AES_128_CBC_SHA",
    0x0035: "RSA_WITH_AES_256_CBC_SHA",
    0x0036: "DH_DSS_WITH_AES_256_CBC_SHA",
    0x0037: "DH_RSA_WITH_AES_256_CBC_SHA",
    0x0038: "DHE_DSS_WITH_AES_256_CBC_SHA",
    0x0039: "DHE_RSA_WITH_AES_256_CBC_SHA",
    0x003b: "RSA_WITH_NULL_SHA256",
    0x003c: "RSA_WITH_AES_128_CBC_SHA256",
    0x003d: "RSA_WITH_AES_256_CBC_SHA256",
    0x003e: "DH_DSS_WITH_AES_128_CBC_SHA256",
    0x003f: "DH_RSA_WITH_AES_128_CBC_SHA256",
    0x0040: "DHE_DSS_WITH_AES_128_CBC_SHA256",
    0x0067: "DHE_RSA_WITH_AES_128_CBC_SHA256",
    0x0068: "DH_DSS_WITH_AES_256_CBC_SHA256",
    0x0069: "DH_RSA_WITH_AES_256_CBC_SHA256",
    0x006a: "DHE_DSS_WITH_AES_256_CBC_SHA256",
    0x006b: "DHE_RSA_WITH_AES_256_CBC_SHA256",
    0x009c: "RSA_WITH_AES_128_GCM_SHA256",
    0x009d: "RSA_WITH_AES_256_GCM_SHA384",
    0x009e: "DHE_RSA_WITH_AES_128_GCM_SHA256",
    0x009f: "DHE_RSA_WITH_AES_256_GCM_SHA384",
    0x00a0: "DH_RSA_WITH_AES_128_GCM_SHA256",
    0x00a1: "DH_RSA_WITH_AES_256_GCM_SHA384",
    0x00a2: "DHE_DSS_WITH_AES_128_GCM_SHA256",
    0x00a3: "DHE_DSS_WITH_AES_256_GCM_SHA384",
    0x00a4: "DH_DSS_WITH_AES_128_GCM_SHA256",
    0x00a5: "DH_DSS_WITH_AES_256_GCM_SHA384",
    0x1301: "AES_128_GCM_SHA256",
    0x1302: "AES_256_GCM_SHA384",
    0x1303: "CHACHA20_POLY1305_SHA256",
    0xc001: "ECDH_ECDSA_WITH_NULL_SHA",
    0xc002: "ECDH_ECDSA_WITH_RC4_128_SHA",
    0xc003: "ECDH_ECDSA_WITH_3DES_EDE_CBC_SHA",
    0xc004: "ECDH_ECDSA_WITH_AES_128_CBC_SHA",
    0xc005: "ECDH_ECDSA_WITH_AES_256_CBC_SHA",
    0xc006: "ECDHE_ECDSA_WITH_NULL_SHA",
    0xc007: "ECDHE_ECDSA_WITH_RC4_128_SHA",
    0xc008: "ECDHE_ECDSA_WITH_3DES_EDE_CBC_SHA",
    0xc009: "ECDHE_ECDSA_WITH_AES_128_CBC_SHA",
    0xc00a: "ECDHE_ECDSA_WITH_AES_256_CBC_SHA",
    0xc00b: "ECDH_RSA_WITH_NULL_SHA",
    0xc00c: "ECDH_RSA_WITH_RC4_128_SHA",
    0xc00d: "ECDH_RSA_WITH_3DES_EDE_CBC_SHA",
    0xc00e: "ECDH_RSA_WITH_AES_128_CBC_SHA",
    0xc00f: "ECDH_RSA_WITH_AES_256_CBC_SHA",
    0xc010: "ECDHE_RSA_WITH_NULL_SHA",
    0xc011: "ECDHE_RSA_WITH_RC4_128_SHA",
    0xc012: "ECDHE_RSA_WITH_3DES_EDE_CBC_SHA",
    0xc013: "ECDHE_RSA_WITH_AES_128_CBC_SHA",
    0xc014: "ECDHE_RSA_WITH_AES_256_CBC_SHA",
    0xc023: "ECDHE_ECDSA_WITH_AES_128_CBC_SHA256",
    0xc024: "ECDHE_ECDSA_WITH_AES_256_CBC_SHA384",
    0xc025: "ECDH_ECDSA_WITH_AES_128_CBC_SHA256",
    0xc026: "ECDH_ECDSA_WITH_AES_256_CBC_SHA384",
    0xc027: "ECDHE_RSA_WITH_AES_128_CBC_SHA256",
    0xc028: "ECDHE_RSA_WITH_AES_256_CBC_SHA384",
    0xc029: "ECDH_RSA_WITH_AES_128_CBC_SHA256",
    0xc02a: "ECDH_RSA_WITH_AES_256_CBC_SHA384",
    0xc02b: "ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
    0xc02c: "ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
    0xc02d: "ECDH_ECDSA_WITH_AES_128_GCM_SHA256",
    0xc02e: "ECDH_ECDSA_WITH_AES_256_GCM_SHA384",
    0xc02f: "ECDHE_RSA_WITH_AES_128_GCM_SHA256",
    0xc030: "ECDHE_RSA_WITH_AES_256_GCM_SHA384",
    0xc031: "ECDH_RSA_WITH_AES_128_GCM_SHA256",
    0xc032: "ECDH_RSA_WITH_AES_256_GCM_SHA384",
    0xcca9: "ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256",
    0xcca8: "ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256",
}
