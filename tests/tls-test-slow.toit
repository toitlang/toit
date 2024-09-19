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

    "dkhostmaster.dk",
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
  2.repeat: | attempt-number |
    error := catch --unwind=(:attempt-number == 1):
      connect-to-site host port expected-certificate-name
    if not error: return
    print "Retrying $host"

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

// Ebay.de sometimes uses this trusted root certificate.
// Serial number 01:FD:6D:30:FC:A3:CA:51:A8:1B:BC:64:0E:35:03:2D
USERTRUST-CERTIFICATE ::= net.Certificate.parse """\
-----BEGIN CERTIFICATE-----
MIIF3jCCA8agAwIBAgIQAf1tMPyjylGoG7xkDjUDLTANBgkqhkiG9w0BAQwFADCB
iDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCk5ldyBKZXJzZXkxFDASBgNVBAcTC0pl
cnNleSBDaXR5MR4wHAYDVQQKExVUaGUgVVNFUlRSVVNUIE5ldHdvcmsxLjAsBgNV
BAMTJVVTRVJUcnVzdCBSU0EgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkwHhcNMTAw
MjAxMDAwMDAwWhcNMzgwMTE4MjM1OTU5WjCBiDELMAkGA1UEBhMCVVMxEzARBgNV
BAgTCk5ldyBKZXJzZXkxFDASBgNVBAcTC0plcnNleSBDaXR5MR4wHAYDVQQKExVU
aGUgVVNFUlRSVVNUIE5ldHdvcmsxLjAsBgNVBAMTJVVTRVJUcnVzdCBSU0EgQ2Vy
dGlmaWNhdGlvbiBBdXRob3JpdHkwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIK
AoICAQCAEmUXNg7D2wiz0KxXDXbtzSfTTK1Qg2HiqiBNCS1kCdzOiZ/MPans9s/B
3PHTsdZ7NygRK0faOca8Ohm0X6a9fZ2jY0K2dvKpOyuR+OJv0OwWIJAJPuLodMkY
tJHUYmTbf6MG8YgYapAiPLz+E/CHFHv25B+O1ORRxhFnRghRy4YUVD+8M/5+bJz/
Fp0YvVGONaanZshyZ9shZrHUm3gDwFA66Mzw3LyeTP6vBZY1H1dat//O+T23LLb2
VN3I5xI6Ta5MirdcmrS3ID3KfyI0rn47aGYBROcBTkZTmzNg95S+UzeQc0PzMsNT
79uq/nROacdrjGCT3sTHDN/hMq7MkztReJVni+49Vv4M0GkPGw/zJSZrM233bkf6
c0Plfg6lZrEpfDKEY1WJxA3Bk1QwGROs0303p+tdOmw1XNtB1xLaqUkL39iAigmT
Yo61Zs8liM2EuLE/pDkP2QKe6xJMlXzzawWpXhaDzLhn4ugTncxbgtNMs+1b/97l
c6wjOy0AvzVVdAlJ2ElYGn+SNuZRkg7zJn0cTRe8yexDJtC/QV9AqURE9JnnV4ee
UB9XVKg+/XRjL7FQZQnmWEIuQxpMtPAlR1n6BB6T1CZGSlCBst6+eLf8ZxXhyVeE
Hg9j1uliutZfVS7qXMYoCAQlObgOK6nyTJccBz8NUvXt7y+CDwIDAQABo0IwQDAd
BgNVHQ4EFgQUU3m/WqorSs9UgOHYm8Cd8rIDZsswDgYDVR0PAQH/BAQDAgEGMA8G
A1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQEMBQADggIBAFzUfA3P9wF9QZllDHPF
Up/L+M+ZBn8b2kMVn54CVVeWFPFSPCeHlCjtHzoBN6J2/FNQwISbxmtOuowhT6KO
VWKR82kV2LyI48SqC/3vqOlLVSoGIG1VeCkZ7l8wXEskEVX/JJpuXior7gtNn3/3
ATiUFJVDBwn7YKnuHKsSjKCaXqeYalltiz8I+8jRRa8YFWSQEg9zKC7F4iRO/Fjs
8PRF/iKz6y+O0tlFYQXBl2+odnKPi4w2r78NBc5xjeambx9spnFixdjQg3IM8WcR
iQycE0xyNN+81XHfqnHd4blsjDwSXWXavVcStkNr/+XeTWYRUc+ZruwXtuhxkYze
Sf7dNXGiFSeUHM9h4ya7b6NnJSFd5t0dCy5oGzuCr+yDZ4XUmFF0sbmZgIn/f3gZ
XHlKYC6SQK5MNyosycdiyA5d9zZbyuAlJQG03RoHnHcAP9Dc1ew91Pq7P8yF1m9/
qS3fuQL39ZeatTXaw2ewh0qpKJ4jjv9cJ2vhsE/zB+4ALtRZh8tSQZXq9EfX7mRB
VXyNWQKV3WKdwrnuWih0hKWbt5DHDAff9Yk2dDLWKMGwsAvgnEzDHNb842m1R0aB
L6KCq9NjRHDEjf8tM7qtj3u1cIiuPhnPQCjY/MiQu12ZIvVS5ljFH4gxQ+6IHdfG
jjxDah2nGN59PRbxYvnKkKj9
-----END CERTIFICATE-----"""

// The ecc256 and ecc384 sites have started using this root.
ISRG-ROOT-X1-TEXT_ ::= """\
-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw
TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
cmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4
WhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu
ZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBY
MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygc
h77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+
0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6U
A5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sW
T8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyH
B5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UC
B5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUv
KBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWn
OlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTn
jh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbw
qHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CI
rU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNV
HRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkq
hkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZL
ubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ
3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj/KK
NFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5
ORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7Ur
TkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdC
jNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVc
oyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq
4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPA
mRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57d
emyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc=
-----END CERTIFICATE-----
"""

// The ecc256 and ecc384 sites have started using this root.
/// ISRG Root X1.
ISRG-ROOT-X1 ::= tls.RootCertificate ISRG-ROOT-X1-TEXT_
