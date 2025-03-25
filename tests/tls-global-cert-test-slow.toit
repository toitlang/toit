// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import net
import net.modules.dns
import net.modules.tcp
import net.x509 as net
import system
import system show platform
import tls

import .tls-global-common

network := net.open

expect-error name [code]:
  error := catch code
  expect: error.contains name

is-embedded ::= platform == system.PLATFORM-FREERTOS

monitor LimitLoad:
  current := 0
  has-test-failure := null
  // FreeRTOS does not have enough memory to run 10 in parallel.
  concurrent-processes ::= is-embedded ? 1 : 2

  inc:
    await: current < concurrent-processes
    current++

  flush:
    await: current == 0

  test-failures:
    await: current == 0
    return has-test-failure

  log-test-failure message:
    has-test-failure = message

  dec:
    current--

load-limiter := LimitLoad

main:
  // While the test runs we have another task that causes a lot of garbage
  // collections, to make sure the TLS handshake does not have any race
  // conditions.
  task --background::
    while true:
      system.process-stats --gc
      yield
  // Install the usual certs.  This should be enough for all these sites.
  add-global-certs

  run-tests

run-tests:
  working := [
    "amazon.com",
    "adafruit.com",
    // "ebay.de",  // Currently the IP that is returned first from DNS has connection refused.

    // Connect to the IP address at the TCP level, but verify the cert name.
    "$(dns.dns-lookup "amazon.com" --network=network)/amazon.com",

    "punktum.dk",
    "dmi.dk",
    "pravda.ru",
    "elpriser.nu",
    "coinbase.com",
    "helsinki.fi",
    "lund.se",
    "web.whatsapp.com",
    "digimedia.com",
    "signal.org",
    ]
  non-working := [
    // This fails because the name we use to connect (an IP address string) doesn't match the cert name.
    "$(dns.dns-lookup "amazon.com" --network=network)",

    "wrong.host.badssl.com/CN_MISMATCH|unknown root cert",
    "self-signed.badssl.com/NOT_TRUSTED",
    "untrusted-root.badssl.com/NOT_TRUSTED",
    "captive-portal.badssl.com",
    "mitm-software.badssl.com",
    "european-union.europa.eu/Starfield",  // Relies on unknown Starfield Tech root.
    "elpais.es/Starfield",                 // Relies on unknown Starfield Tech root.
    "vw.de/Starfield",                     // Relies on unknown Starfield Tech root.
    "moxie.org/Starfield",                 // Relies on unknown Starfield Tech root.
    ]
  working.do: | site |
    test-site site true
    if load-limiter.has-test-failure: throw load-limiter.has-test-failure  // End early if we have a test failure.
  non-working.do: | site |
    test-site site false
    if load-limiter.has-test-failure: throw load-limiter.has-test-failure  // End early if we have a test failure.
  if load-limiter.test-failures:
    throw load-limiter.has-test-failure

test-site url expect-ok:
  host := url
  extra-info := null
  if (host.index-of "/") != -1:
    parts := host.split "/"
    host = parts[0]
    extra-info = parts[1]
  port := 443
  if (url.index-of ":") != -1:
    array := url.split ":"
    host = array[0]
    port = int.parse array[1]
  load-limiter.inc
  if expect-ok:
    task:: working-site host port extra-info
  else:
    task:: non-working-site host port extra-info

non-working-site site port exception-text1:
  exception-text2 := null
  if exception-text1 and exception-text1.contains "|":
    parts := exception-text1.split "|"
    exception-text2 = parts[0]
    exception-text1 = parts[1]

  test-failure := false
  exception ::= catch:
    connect-to-site site port site
    load-limiter.log-test-failure "*** Incorrectly failed to reject SSL connection to $site ***"
    test-failure = true
  if not test-failure:
    if exception-text1 and ("$exception".index-of exception-text1) == -1 and (not exception-text2 or ("$exception".index-of exception-text2) == -1):
      print "$site:$port: Was expecting exception:"
      print "  $exception"
      print "to contain the phrase '$exception-text1' or '$exception-text2'"
      load-limiter.log-test-failure "Wrong error message"
  load-limiter.dec

working-site host port expected-certificate-name:
  error := true
  try:
    connect-to-site-with-retry host port expected-certificate-name
    error = false
  finally:
    if error:
      load-limiter.log-test-failure "*** Incorrectly failed to connect to $host ***"
    load-limiter.dec

connect-to-site-with-retry host port expected-certificate-name:
  2.repeat: | attempt-number |
    error := catch --unwind=(:attempt-number == 1):
      connect-to-site host port expected-certificate-name
    if not error: return

connect-to-site host port expected-certificate-name:
  bytes := 0
  connection := null

  raw := tcp.TcpSocket network
  try:
    raw.connect host port

    socket := tls.Socket.client raw
      --server-name=expected-certificate-name or host

    expect-not socket.session-resumed  // Not connected yet.

    try:
      writer := socket.out
      writer.write """GET / HTTP/1.1\r\nHost: $host\r\nConnection: close\r\n\r\n"""
      print "$host: $((socket as any).session_.mode == tls.SESSION-MODE-TOIT ? "Toit mode" : "MbedTLS mode")"

      reader := socket.in
      while data := reader.read:
        bytes += data.size

    finally:
      socket.close
  finally:
    raw.close
    if connection: connection.close

    print "Read $bytes bytes from https://$host$(port == 443 ? "" : ":$port")/"

add-global-certs -> none:
  // Test binary (DER) roots.
  tls.add-global-root-certificate_ DIGICERT-GLOBAL-ROOT-G2-BYTES 0x025449c2
  tls.add-global-root-certificate_ DIGICERT-GLOBAL-ROOT-CA-BYTES
  // Test roots that are RootCertificate objects.
  GLOBALSIGN-ROOT-CA-BYTES.install  // Needed for pravda.ru.
  GLOBALSIGN-ROOT-CA-R3-BYTES.install  // Needed for lund.se.
  COMODO-RSA-CERTIFICATION-AUTHORITY-BYTES.install  // Needed for elpriser.nu.
  BALTIMORE-CYBERTRUST-ROOT-BYTES.install  // Needed for coinbase.com.
  // Test a binary root that is a modified copy-on-write byte array.
  USERTRUST-ECC-CERTIFICATION-AUTHORITY-BYTES[42] ^= 42
  USERTRUST-ECC-CERTIFICATION-AUTHORITY-BYTES[42] ^= 42
  tls.add-global-root-certificate_ USERTRUST-ECC-CERTIFICATION-AUTHORITY-BYTES  // Needed for helsinki.fi.
  // Test ASCII (PEM) roots.
  tls.add-global-root-certificate_ USERTRUST-RSA-CERTIFICATE-TEXT 0x0c49cbaf  // Needed for dmi.dk.
  tls.add-global-root-certificate_ ISRG-ROOT-X1-TEXT  // Needed by punktum.dk and digimedia.com.
  // Test that the cert can be a slice.
  tls.add-global-root-certificate_ DIGICERT-ROOT-TEXT[..DIGICERT-ROOT-TEXT.size - 9]
  tls.add-global-root-certificate_ COMODO-AAA-SERVICES-ROOT-BYTES_

  // Test that we get a sensible error when trying to add a parsed root
  // certificate.
  parsed := net.Certificate.parse USERTRUST-RSA-CERTIFICATE-TEXT
  expect-error "WRONG_OBJECT_TYPE": tls.add-global-root-certificate_ parsed

  // Test that unparseable cert gives an immediate error.
  if not is-embedded:
    expect-error "OID is not found":
      DIGICERT-GLOBAL-ROOT-CA-BYTES[42] ^= 42
      tls.add-global-root-certificate_ DIGICERT-GLOBAL-ROOT-CA-BYTES

  // Test that it's not too costly to add the same cert multiple times.
  (is-embedded ? 1000 : 1_000_000).repeat:
    tls.add-global-root-certificate_ DIGICERT-GLOBAL-ROOT-G2-BYTES 0x025449c2
