// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import certificate-roots
import tls
import net
import net.modules.dns
import net.modules.tcp
import net.x509 as net
import system
import system show platform

BIG-MEMORY ::= platform != system.PLATFORM-FREERTOS
CHECK-CERTS-EXPIRE ::= platform != system.PLATFORM-FREERTOS

network := net.open

monitor LimitLoad:
  current := 0
  has-test-failure := null
  // FreeRTOS does not have enough memory to run 10 in parallel.
  concurrent-processes ::= BIG-MEMORY ? 3 : 1

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
  run-tests

run-tests:
  working := [
    "amazon.com",
    "adafruit.com",
    // "ebay.de",  // Currently the IP that is returned first from DNS has connection refused.

    // Connect to the IP address at the TCP level, but verify the cert name.
    "$(dns.dns-lookup "amazon.com" --network=network)/amazon.com",

    "punktum.dk",
    "gnu.org",  // Doesn't work with Toit mode, falls back to MbedTLS C code for symmetric stage.

    "sha256.badssl.com",
    "ecc256.badssl.com",
    "ecc384.badssl.com",
    "rsa2048.badssl.com",
    "rsa4096.badssl.com",
    "mozilla-modern.badssl.com",
    "tls-v1-2.badssl.com:1012",
    "hsts.badssl.com",
    "upgrade.badssl.com",
    "preloaded-hsts.badssl.com",
    "https-everywhere.badssl.com",
    "long-extended-subdomain-name-containing-many-letters-and-dashes.badssl.com",
    "longextendedsubdomainnamewithoutdashesinordertotestwordwrapping.badssl.com",
    // "dh2048.badssl.com"  // Diffie Hellman doesn't work in Chrome either.
    ]
  expired := [
    "sha384.badssl.com",
    "sha512.badssl.com",
  ]
  non-working := [
    // This fails because the name we use to connect (an IP address string) doesn't match the cert name.
    "$(dns.dns-lookup "amazon.com" --network=network)",

    "wrong.host.badssl.com/CN_MISMATCH|nknown root cert",
    "self-signed.badssl.com/Certificate verification failed|nknown root cert",
    "untrusted-root.badssl.com/Certificate verification failed|nknown root cert",
    //  "revoked.badssl.com",  // We don't have support for cert revocation yet.
    //  "pinning-test.badssl.com",  // We don't have support for cert pinning yet.
    "sha1-intermediate.badssl.com/EXPIRED|BAD_MD",
    // The peer rejects us here because we don't have any hash algorithm in common.
    "rc4-md5.badssl.com/7780|received from our peer",
    "rc4.badssl.com/7780|received from our peer",
    "null.badssl.com/7780|received from our peer",
    "3des.badssl.com",
    //  "mozilla-old.badssl.com",  // Chrome allows this one too
    "dh480.badssl.com",
    "dh512.badssl.com",
    //  "dh-small-subgroup.badssl.com", // Should we not connect to sites with crappy certs?
    //  "dh-composite.badssl.com", // Should we not connect to sites with crappy certs?
    "subdomain.preloaded-hsts.badssl.com/CN_MISMATCH",
    "captive-portal.badssl.com",
    "mitm-software.badssl.com",
    "sha1-2017.badssl.com/BAD_MD",
    "sha1.badssl.com/BAD_MD",
    ]
  if CHECK-CERTS-EXPIRE:
    expired.do: non-working.add "$it/EXPIRED"
  else:
    working.add-all expired
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

non-working-site site port exception-text-in/string?:
  exception-text/List? := null
  if exception-text-in:
    exception-text = exception-text-in.split "|"

  test-failure := false
  exception ::= catch:
    connect-to-site site port site
    load-limiter.log-test-failure "*** Incorrectly failed to reject SSL connection to $site ***"
    test-failure = true
  if not test-failure:
    if exception-text and (exception-text.every: ("$exception".index-of it) == -1):
      print "$site:$port: Was expecting exception:"
      print "  $exception"
      print "to contain one of $exception-text-in"
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
  attempts ::= 3
  delay-between-attempts ::= Duration --s=1
  attempts.repeat: | attempt-number |
    error := catch --unwind=(:attempt-number == attempts - 1):
      connect-to-site host port expected-certificate-name
    if not error: return
    sleep delay-between-attempts
    print "Retrying $host after delaying for $delay-between-attempts"

connect-to-site host port expected-certificate-name:
  bytes := 0
  connection := null

  raw := tcp.TcpSocket network
  try:
    raw.connect host port

    ROOTS ::= [
        certificate-roots.DIGICERT-HIGH-ASSURANCE-EV-ROOT-CA,
        certificate-roots.DIGICERT-GLOBAL-ROOT-CA,
        certificate-roots.DIGICERT-GLOBAL-ROOT-G2,
        certificate-roots.USERTRUST-RSA-CERTIFICATION-AUTHORITY,
        certificate-roots.USERTRUST-ECC-CERTIFICATION-AUTHORITY,
        certificate-roots.ISRG-ROOT-X1,
    ]
    socket := tls.Socket.client raw
      --root-certificates=ROOTS
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
    raw.close
    if connection: connection.close

    print "Read $bytes bytes from https://$host$(port == 443 ? "" : ":$port")/"
