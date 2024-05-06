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

monitor LimitLoad:
  current := 0
  has-test-failure := null
  // FreeRTOS does not have enough memory to run 10 in parallel.
  concurrent-processes ::= 4

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
  add-global-certs
  if system.platform != "Windows": return

  network = net.open
  try:
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
  // Test that the built-in root certs in the Windows
  // installation are sufficient.
  tls.use-system-trusted-root-certificates
