// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import tls
import net
import net.x509
import system
import system show platform

import .tls-global-common

expect-error name [code]:
  error := catch code
  expect: error.contains name

is-embedded ::= platform == system.PLATFORM-FREERTOS

monitor LimitLoad:
  current := 0
  has-test-failure := null
  // FreeRTOS does not have enough memory to run 10 in parallel.
  concurrent-processes ::= is-embedded ? 1 : 1

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

network/net.Client? := null

main:
  network = net.open
  try:
    add-global-certs
    run-tests
  finally:
    network.close

run-tests:
  working := [
    "amazon.com",
    "adafruit.com",
    "dkhostmaster.dk",
    "dmi.dk",
    "pravda.ru",
    "elpriser.nu",
    "coinbase.com",
    "helsinki.fi",
    "lund.se",
    "web.whatsapp.com",
    "digimedia.com",
  ]
  working.do: | site |
    test-site site
    if load-limiter.has-test-failure: throw load-limiter.has-test-failure  // End early if we have a test failure.
  if load-limiter.test-failures:
    throw load-limiter.has-test-failure

test-site url:
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
  working-site host port extra-info

working-site host port expected-certificate-name:
  error := true
  try:
    connect-to-site host port expected-certificate-name
    error = false
  finally:
    if error:
      load-limiter.log-test-failure "*** Incorrectly failed to connect to $host ***"
    load-limiter.dec

connect-to-site host port expected-certificate-name:
  bytes := 0
  connection := null

  tcp-socket := network.tcp-connect host port
  try:
    socket := tls.Socket.client tcp-socket
      --server-name=expected-certificate-name or host

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
    tcp-socket.close
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
  tls.add-global-root-certificate_ ISRG-ROOT-X1-TEXT  // Needed by dkhostmaster.dk and digimedia.com.
  // Test that the cert can be a slice.
  tls.add-global-root-certificate_ DIGICERT-ROOT-TEXT[..DIGICERT-ROOT-TEXT.size - 9]
  tls.add-global-root-certificate_ COMODO-AAA-SERVICES-ROOT-BYTES_

  // Test that we get a sensible error when trying to add a parsed root
  // certificate.
  parsed := x509.Certificate.parse USERTRUST-RSA-CERTIFICATE-TEXT
  expect-error "WRONG_OBJECT_TYPE": tls.add-global-root-certificate_ parsed

  // Test that unparseable cert gives an immediate error.
  if not is-embedded:
    expect-error "OID is not found":
      DIGICERT-GLOBAL-ROOT-CA-BYTES[42] ^= 42
      tls.add-global-root-certificate_ DIGICERT-GLOBAL-ROOT-CA-BYTES

  // Test that it's not too costly to add the same cert multiple times.
  (is-embedded ? 1000 : 1_000_000).repeat:
    tls.add-global-root-certificate_ DIGICERT-GLOBAL-ROOT-G2-BYTES 0x025449c2
