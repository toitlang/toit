// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .dns
import expect show *
import writer
import tls
import .tcp as tcp
import net.x509 as net

expect_error name [code]:
  expect_equals
    name
    catch code

monitor LimitLoad:
  current := 0
  has_test_failure := null
  // FreeRTOS does not have enough memory to run 10 in parallel.
  concurrent_processes ::= platform == "FreeRTOS" ? 1 : 2

  inc:
    await: current < concurrent_processes
    current++

  flush:
    await: current == 0

  test_failures:
    await: current == 0
    return has_test_failure

  log_test_failure message:
    has_test_failure = message

  dec:
    current--

load_limiter := LimitLoad

main:
  add_global_certs
  run_tests

run_tests:
  working := [
    "amazon.com",
    "adafruit.com",
    // "ebay.de",  // Currently the IP that is returned first from DNS has connection refused.
    "$(dns_lookup "amazon.com")/amazon.com",  // Connect to the IP address at the TCP level, but verify the cert name.

    "dkhostmaster.dk",

    "sha256.badssl.com",
    // "sha384.badssl.com",  Expired.
    // "sha512.badssl.com",  Expired.
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
  non_working := [
    "$(dns_lookup "amazon.com")",   // This fails because the name we use to connect (an IP address string) doesn't match the cert name.
    "wrong.host.badssl.com/Common Name|unknown root cert",
    "self-signed.badssl.com/Certificate verification failed|unknown root cert",
    "untrusted-root.badssl.com/Certificate verification failed|unknown root cert",
    //  "revoked.badssl.com",  // We don't have support for cert revocation yet.
    //  "pinning-test.badssl.com",  // We don't have support for cert pinning yet.
    //  "sha1-intermediate.badssl.com/unacceptable hash",  // Expired.
    // The peer rejects us here because we don't have any hash algorithm in common.
    "rc4-md5.badssl.com/7780|received from our peer",
    "rc4.badssl.com/7780|received from our peer",
    "null.badssl.com/7780|received from our peer",
    //  "3des.badssl.com",         // Chrome allows this one too
    //  "mozilla-old.badssl.com",  // Chrome allows this one too
    "dh480.badssl.com",
    "dh512.badssl.com",
    //  "dh-small-subgroup.badssl.com", // Should we not connect to sites with crappy certs?
    //  "dh-composite.badssl.com", // Should we not connect to sites with crappy certs?
    "subdomain.preloaded-hsts.badssl.com/Common Name",
    "captive-portal.badssl.com",
    "mitm-software.badssl.com",
    "sha1-2017.badssl.com",
    "european-union.europa.eu/Starfield",  // Relies on unknown Starfield Tech root.
    ]
  working.do: | site |
    test_site site true
    if load_limiter.has_test_failure: throw load_limiter.has_test_failure  // End early if we have a test failure.
  non_working.do: | site |
    test_site site false
    if load_limiter.has_test_failure: throw load_limiter.has_test_failure  // End early if we have a test failure.
  if load_limiter.test_failures:
    throw load_limiter.has_test_failure

test_site url expect_ok:
  host := url
  extra_info := null
  if (host.index_of "/") != -1:
    parts := host.split "/"
    host = parts[0]
    extra_info = parts[1]
  port := 443
  if (url.index_of ":") != -1:
    array := url.split ":"
    host = array[0]
    port = int.parse array[1]
  load_limiter.inc
  if expect_ok:
    task:: working_site host port extra_info
  else:
    task:: non_working_site host port extra_info

non_working_site site port exception_text1:
  exception_text2 := null
  if exception_text1 and exception_text1.contains "|":
    parts := exception_text1.split "|"
    exception_text2 = parts[0]
    exception_text1 = parts[1]

  test_failure := false
  exception ::= catch:
    connect_to_site site port site
    load_limiter.log_test_failure "*** Incorrectly failed to reject SSL connection to $site ***"
    test_failure = true
  if not test_failure:
    if exception_text1 and ("$exception".index_of exception_text1) == -1 and (not exception_text2 or ("$exception".index_of exception_text2) == -1):
      print "$site:$port: Was expecting exception:"
      print "  $exception"
      print "to contain the phrase '$exception_text1' or '$exception_text2'"
      load_limiter.log_test_failure "Wrong error message"
  load_limiter.dec

working_site host port expected_certificate_name:
  error := true
  try:
    connect_to_site host port expected_certificate_name
    error = false
  finally:
    if error:
      load_limiter.log_test_failure "*** Incorrectly failed to connect to $host ***"
    load_limiter.dec

connect_to_site host port expected_certificate_name:
  bytes := 0
  connection := null

  raw := tcp.TcpSocket
  try:
    raw.connect host port

    socket := tls.Socket.client raw
      --server_name=expected_certificate_name or host

    try:
      writer := writer.Writer socket
      writer.write """GET / HTTP/1.1\r\nHost: $host\r\nConnection: close\r\n\r\n"""
      print "$host: $((socket as any).session_.mode == tls.SESSION_MODE_TOIT ? "Toit mode" : "MbedTLS mode")"

      while data := socket.read:
        bytes += data.size

    finally:
      socket.close
  finally:
    raw.close
    if connection: connection.close

    print "Read $bytes bytes from https://$host$(port == 443 ? "" : ":$port")/"

add_global_certs -> none:
  // Test binary (DER) roots.
  tls.add_global_root_certificate DIGICERT_GLOBAL_ROOT_G2_BYTES 0x025449c2
  tls.add_global_root_certificate DIGICERT_GLOBAL_ROOT_CA_BYTES
  // Test ASCII (PEM) roots.
  tls.add_global_root_certificate USERTRUST_CERTIFICATE_TEXT 0x0c49cbaf
  tls.add_global_root_certificate ISRG_ROOT_X1_TEXT
  // Test that the cert can be a slice.
  tls.add_global_root_certificate DIGICERT_ROOT_TEXT[..DIGICERT_ROOT_TEXT.size - 9]
  // Test a binary root that is a modified copy-on-write byte array.
  DIGICERT_ASSURED_ID_ROOT_G3_BYTES[42] ^= 42
  DIGICERT_ASSURED_ID_ROOT_G3_BYTES[42] ^= 42
  tls.add_global_root_certificate DIGICERT_ASSURED_ID_ROOT_G3_BYTES

  // Test that we get a sensible error when trying to add a parsed root
  // certificate.
  parsed := net.Certificate.parse DIGICERT_ASSURED_ID_ROOT_G3_BYTES
  expect_error "WRONG_OBJECT_TYPE": tls.add_global_root_certificate parsed

  // Test that unparseable cert gives an immediate error.
  DIGICERT_ASSURED_ID_ROOT_G3_BYTES[42] ^= 42
  tls.add_global_root_certificate DIGICERT_ASSURED_ID_ROOT_G3_BYTES

// Ebay.de sometimes uses this trusted root certificate.
// Serial number 01:FD:6D:30:FC:A3:CA:51:A8:1B:BC:64:0E:35:03:2D
USERTRUST_CERTIFICATE_TEXT ::= """\
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
ISRG_ROOT_X1_TEXT ::= """\
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

DIGICERT_ROOT_TEXT ::= """
-----BEGIN CERTIFICATE-----
MIIDxTCCAq2gAwIBAgIQAqxcJmoLQJuPC3nyrkYldzANBgkqhkiG9w0BAQUFADBs
MQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3
d3cuZGlnaWNlcnQuY29tMSswKQYDVQQDEyJEaWdpQ2VydCBIaWdoIEFzc3VyYW5j
ZSBFViBSb290IENBMB4XDTA2MTExMDAwMDAwMFoXDTMxMTExMDAwMDAwMFowbDEL
MAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQd3d3
LmRpZ2ljZXJ0LmNvbTErMCkGA1UEAxMiRGlnaUNlcnQgSGlnaCBBc3N1cmFuY2Ug
RVYgUm9vdCBDQTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAMbM5XPm
+9S75S0tMqbf5YE/yc0lSbZxKsPVlDRnogocsF9ppkCxxLeyj9CYpKlBWTrT3JTW
PNt0OKRKzE0lgvdKpVMSOO7zSW1xkX5jtqumX8OkhPhPYlG++MXs2ziS4wblCJEM
xChBVfvLWokVfnHoNb9Ncgk9vjo4UFt3MRuNs8ckRZqnrG0AFFoEt7oT61EKmEFB
Ik5lYYeBQVCmeVyJ3hlKV9Uu5l0cUyx+mM0aBhakaHPQNAQTXKFx01p8VdteZOE3
hzBWBOURtCmAEvF5OYiiAhF8J2a3iLd48soKqDirCmTCv2ZdlYTBoSUeh10aUAsg
EsxBu24LUTi4S8sCAwEAAaNjMGEwDgYDVR0PAQH/BAQDAgGGMA8GA1UdEwEB/wQF
MAMBAf8wHQYDVR0OBBYEFLE+w2kD+L9HAdSYJhoIAu9jZCvDMB8GA1UdIwQYMBaA
FLE+w2kD+L9HAdSYJhoIAu9jZCvDMA0GCSqGSIb3DQEBBQUAA4IBAQAcGgaX3Nec
nzyIZgYIVyHbIUf4KmeqvxgydkAQV8GK83rZEWWONfqe/EW1ntlMMUu4kehDLI6z
eM7b41N5cdblIZQB2lWHmiRk9opmzN6cN82oNLFpmyPInngiK3BD41VHMWEZ71jF
hS9OMPagMRYjyOfiZRYzy78aG6A9+MpeizGLYAiJLQwGXFK3xPkKmNEVX58Svnw2
Yzi9RKR/5CYrCsSXaQ3pjOLAEFe4yHYSkVXySGnYvCoCWw9E1CAx2/S6cCZdkGCe
vEsXCS+0yx5DaMkHJ8HSXPfqIbloEpw8nL+e/IBcm2PN7EeqJSdnoDfzAIJ9VNep
+OkuE6N36B9K
-----END CERTIFICATE-----horsefish"""

DIGICERT_GLOBAL_ROOT_CA_BYTES ::= #[
    '0',0x82,0x3,175,'0',130,2,151,160,3,2,1,2,2,16,8,';',224,'V',144,'B','F',
    177,161,'u','j',201,'Y',145,199,'J','0',13,6,9,'*',134,'H',134,247,13,1,1,
    5,5,0,'0','a','1',11,'0',9,6,3,'U',4,6,19,2,'U','S','1',21,'0',19,6,3,'U',
    4,0xa,19,12,'D','i','g','i','C','e','r','t',' ','I','n','c','1',25,'0',23,
    0x06,3,'U',4,11,19,16,'w','w','w','.','d','i','g','i','c','e','r','t','.',
    'c','o','m','1',' ','0',30,6,3,'U',4,3,19,23,'D','i','g','i','C','e','r',
    't',' ','G','l','o','b','a','l',' ','R','o','o','t',' ','C','A','0',30,23,
    0xd,'0','6','1','1','1','0','0','0','0','0','0','0','Z',23,13,'3','1','1',
    '1','1','0','0','0','0','0','0','0','Z','0','a','1',0xb,'0',9,6,3,'U',4,6,
    19,2,'U','S','1',21,'0',19,6,3,'U',4,10,19,12,'D','i','g','i','C','e','r',
    't',' ','I','n','c','1',25,'0',23,6,3,'U',4,0xb,19,16,'w','w','w','.','d',
    'i','g','i','c','e','r','t','.','c','o','m','1',' ','0',30,6,3,'U',4,3,19,
    0x17,'D','i','g','i','C','e','r','t',' ','G','l','o','b','a','l',' ','R',
    'o','o','t',' ','C','A','0',130,1,'"','0',13,6,9,'*',134,'H',134,247,13,1,
    1,1,5,0,3,0x82,1,15,0,'0',130,1,10,2,130,1,1,0,226,';',225,17,'r',222,168,
    164,211,163,'W',170,'P',162,143,11,'w',144,201,162,165,238,18,206,150,'[',
    0x1,9,' ',204,1,147,167,'N','0',183,'S',247,'C',196,'i',0,'W',157,226,141,
    '"',0xdd,135,6,'@',0,129,9,206,206,27,131,191,223,205,';','q','F',226,214,
    'f',0xc7,5,179,'v',39,22,143,'{',158,30,149,'}',238,183,'H',163,8,218,214,
    0xaf,'z',0x0c,'9',6,'e',127,'J',']',31,188,23,248,171,190,238,'(',215,'t',
    0x7f,'z','x',0x99,'Y',0x85,'h','n',92,'#','2','K',191,'N',192,232,'Z','m',
    0xe3,'p',0xbf,'w',16,0xbf,252,1,246,133,217,168,'D',16,'X','2',169,'u',24,
    0xd5,209,162,190,'G',226,39,'j',244,154,'3',248,'I',8,'`',139,212,'_',180,
    ':',0x84,0xbf,161,170,'J','L','}','>',207,'O','_','l','v','^',160,'K','7',
    0x91,0x9e,220,'"',230,'m',206,20,26,142,'j',203,254,205,179,20,'d',23,199,
    '[',')',158,'2',191,242,238,250,211,11,'B',212,171,183,'A','2',218,12,212,
    0xef,248,129,213,187,141,'X','?',181,27,232,'I','(',162,'p',218,'1',4,221,
    0xf7,0xb2,22,242,'L',10,'N',7,168,237,'J','=','^',181,127,163,144,195,175,
    0x27,2,3,1,0,1,163,'c','0','a','0',14,6,3,'U',29,15,1,1,255,4,4,3,2,1,134,
    '0',0xf,6,3,'U',29,19,1,1,255,4,5,'0',3,1,1,255,'0',29,6,3,'U',29,14,4,22,
    4,20,3,0xde,'P','5','V',209,'L',187,'f',240,163,226,27,27,195,151,178,'=',
    0xd1,'U','0',0x1f,6,3,'U',29,'#',4,24,'0',22,128,20,3,222,'P','5','V',209,
    'L',0xbb,'f',240,163,226,27,27,195,151,178,'=',209,'U','0',13,6,9,'*',134,
    'H',134,247,13,1,1,5,5,0,3,130,1,1,0,203,156,'7',170,'H',19,18,10,250,221,
    'D',0x9c,'O','R',0xb0,0xf4,223,174,4,245,'y','y',8,163,'$',24,252,'K','+',
    0x84,0xc0,'-',0xb9,213,199,254,244,193,31,'X',203,184,'m',156,'z','t',231,
    0x98,')',0xab,17,0xb5,227,'p',160,161,205,'L',136,153,147,140,145,'p',226,
    171,15,28,190,147,169,255,'c',213,228,7,'`',211,163,191,157,'[',9,241,213,
    0x8e,0xe3,'S',244,142,'c',250,'?',167,219,180,'f',223,'b','f',214,209,'n',
    'A',0x8d,0xf2,'-',181,234,'w','J',159,157,'X',226,'+','Y',192,'@','#',237,
    '-','(',0x82,'E','>','y','T',0x92,'&',152,224,128,'H',168,'7',239,240,214,
    'y','`',22,0xde,172,232,14,205,'n',172,'D',23,'8','/','I',218,225,'E','>',
    '*',0xb9,'6','S',207,':','P',6,247,'.',232,196,'W','I','l','a','!',24,213,
    0x4,173,'x','<',',',':',128,'k',167,235,175,21,20,233,216,137,193,185,'8',
    'l',0xe2,0x91,'l',0x8a,255,'d',185,'w','%','W','0',192,27,'$',163,225,220,
    0xe9,0xdf,'G','|',0xb5,180,'$',8,5,'0',236,'-',189,11,191,'E',191,'P',185,
    0xa9,0xf3,235,152,1,18,173,200,136,198,152,'4','_',141,10,'<',198,233,213,
    149,149,'m',222,
]

DIGICERT_GLOBAL_ROOT_G2_BYTES ::= #[
    '0',130,3,142,'0',130,2,'v',160,3,2,1,2,2,16,3,':',241,230,167,17,169,160,
    187,'(','d',177,29,9,250,229,'0',13,6,9,'*',134,'H',134,247,13,1,1,11,5,0,
    '0','a','1',0xb,'0',9,6,3,'U',4,6,19,2,'U','S','1',21,'0',19,6,3,'U',4,10,
    0x13,12,'D','i','g','i','C','e','r','t',' ','I','n','c','1',25,'0',23,6,3,
    'U',0x04,11,19,16,'w','w','w','.','d','i','g','i','c','e','r','t','.','c',
    'o','m','1',' ','0',30,6,3,'U',4,3,19,23,'D','i','g','i','C','e','r','t',
    ' ','G','l','o','b','a','l',' ','R','o','o','t',' ','G','2','0',30,23,0xd,
    '1','3','0','8','0','1','1','2','0','0','0','0','Z',23,13,'3','8','0','1',
    '1','5','1','2','0','0','0','0','Z','0','a','1',11,'0',9,6,3,'U',4,6,19,2,
    'U','S','1',21,'0',19,6,3,'U',4,0xa,19,12,'D','i','g','i','C','e','r','t',
    ' ','I','n','c','1',25,'0',23,6,3,'U',4,0xb,19,16,'w','w','w','.','d','i',
    'g','i','c','e','r','t','.','c','o','m','1',' ','0',30,6,3,'U',4,3,19,23,
    'D','i','g','i','C','e','r','t',' ','G','l','o','b','a','l',' ','R','o',
    'o','t',' ','G','2','0',130,1,'"','0',13,6,9,'*',134,'H',134,247,13,1,1,1,
    5,0,3,130,1,15,0,'0',130,1,10,2,130,1,1,0,187,'7',205,'4',220,'{','k',201,
    0xb2,'h',0x90,173,'J','u',255,'F',186,'!',10,8,141,245,25,'T',201,251,136,
    0xdb,243,174,242,':',137,145,'<','z',230,171,6,26,'k',207,172,'-',232,'^',
    0x9,'$','D',186,'b',154,'~',214,163,168,'~',224,'T','u',' ',5,172,'P',183,
    0x9c,'c',26,'l','0',0xdc,218,31,25,177,215,30,222,253,215,224,203,148,131,
    '7',0xae,0xec,31,'C','N',0xdd,'{',',',210,189,'.',165,'/',228,169,184,173,
    ':',0xd4,153,164,182,'%',233,155,'k',0,'`',146,'`',255,'O','!','I',24,247,
    'g',144,171,'a',6,156,143,242,186,233,180,233,146,'2','k',181,243,'W',232,
    ']',0x1b,205,140,29,171,149,4,149,'I',243,'5','-',150,227,'I','m',221,'w',
    227,251,'I','K',180,172,'U',7,169,143,149,179,180,'#',187,'L','m','E',240,
    246,169,178,149,'0',180,253,'L','U',140,39,'J','W',20,'|',130,157,205,'s',
    0x92,0xd3,22,'J',6,12,140,'P',209,143,30,9,190,23,161,230,'!',202,253,131,
    0xe5,0x10,188,131,165,10,196,'g','(',246,'s',20,20,'=','F','v',195,135,20,
    137,'!','4','M',175,15,'E',12,166,'I',161,186,187,156,197,177,'3',131,')',
    0x85,2,3,1,0,1,163,'B','0','@','0',15,6,3,'U',29,19,1,1,255,4,5,'0',3,1,1,
    0xff,'0',14,6,3,'U',29,15,1,1,255,4,4,3,2,1,134,'0',29,6,3,'U',29,14,4,22,
    0x04,20,'N','"','T',' ',24,149,230,227,'n',230,15,250,250,185,18,237,6,23,
    0x8f,'9','0',13,6,9,'*',134,'H',134,247,13,1,1,11,5,0,3,130,1,1,0,'`','g',
    '(',148,'o',14,'H','c',235,'1',221,234,'g',24,213,137,'}','<',197,139,'J',
    127,233,190,219,'+',23,223,176,'_','s','w','*','2',19,'9',129,'g','B',132,
    '#',0xf2,'E','g','5',0xec,0x88,191,248,143,176,'a',12,'4',164,174,' ','L',
    132,198,219,248,'5',225,'v',217,223,166,'B',187,199,'D',8,134,127,'6','t',
    '$','Z',0xda,'l',0xd,20,'Y','5',189,242,'I',221,182,31,201,179,13,'G','*',
    '=',153,'/',187,92,187,181,212,' ',225,153,'_','S','F',21,219,'h',155,240,
    0xf3,'0',0xd5,'>','1',0xe2,141,132,158,227,138,218,218,150,'>','5',19,165,
    '_',240,249,'p','P','p','G','A',17,'W',25,'N',192,143,174,6,196,149,19,23,
    '/',27,'%',159,'u',242,177,142,153,161,'o',19,177,'A','q',254,136,'*',200,
    'O',16,' ','U',0xd7,243,20,'E',229,224,'D',244,234,135,149,'2',147,14,254,
    'S','F',250,',',157,255,139,'"',185,'K',217,9,'E',164,222,164,184,154,'X',
    221,27,'}','R',159,142,'Y','C',136,129,164,158,'&',213,'o',173,221,13,198,
    '7','}',0xed,3,146,27,229,'w','_','v',238,'<',141,196,']','V','[',162,217,
    'f','n',179,'5','7',229,'2',182,
]

DIGICERT_ASSURED_ID_ROOT_G3_BYTES ::= #[
    '0',0x82,0x2,'F','0',130,1,205,160,3,2,1,2,2,16,11,161,'Z',250,29,223,160,
    0xb5,'I','D',175,205,'$',160,'l',236,'0',10,6,8,'*',134,'H',206,'=',4,3,3,
    '0','e','1',0xb,'0',9,6,3,'U',4,6,19,2,'U','S','1',21,'0',19,6,3,'U',4,10,
    0x13,12,'D','i','g','i','C','e','r','t',' ','I','n','c','1',25,'0',23,6,3,
    'U',0x04,11,19,16,'w','w','w','.','d','i','g','i','c','e','r','t','.','c',
    'o','m','1','$','0','"',6,3,'U',4,3,19,27,'D','i','g','i','C','e','r','t',
    ' ','A','s','s','u','r','e','d',' ','I','D',' ','R','o','o','t',' ','G',
    '3','0',0x1e,23,13,'1','3','0','8','0','1','1','2','0','0','0','0','Z',23,
    13,'3','8','0','1','1','5','1','2','0','0','0','0','Z','0','e','1',11,'0',
    0x9,6,3,'U',4,6,19,2,'U','S','1',21,'0',19,6,3,'U',4,10,19,12,'D','i','g',
    'i','C','e','r','t',' ','I','n','c','1',25,'0',23,6,3,'U',4,0xb,19,16,'w',
    'w','w','.','d','i','g','i','c','e','r','t','.','c','o','m','1','$','0',
    '"',6,3,'U',4,3,19,27,'D','i','g','i','C','e','r','t',' ','A','s','s','u',
    'r','e','d',' ','I','D',' ','R','o','o','t',' ','G','3','0','v','0',16,6,
    0x07,'*',134,'H',206,'=',2,1,6,5,'+',129,4,0,'"',3,'b',0,4,25,231,188,172,
    'D','e',0xed,0xcd,184,'?','X',251,141,177,'W',169,'D','-',5,21,242,239,11,
    0xff,16,'t',0x9f,181,'b','R','_','f','~',31,229,220,27,'E','y',11,204,198,
    'S',10,157,141,']',2,217,169,'Y',222,2,'Z',246,149,'*',14,141,'8','J',138,
    'I',0xc6,188,198,3,'8',7,'_','U',218,'~',9,'n',226,127,'^',208,'E',' ',15,
    'Y','v',0x10,0xd6,160,'$',240,'-',222,'6',242,'l',')','9',163,'B','0','@',
    '0',0x0f,6,3,'U',29,19,1,1,255,4,5,'0',3,1,1,255,'0',14,6,3,'U',29,15,1,1,
    0xff,4,4,3,2,1,134,'0',29,6,3,'U',29,14,4,22,4,20,203,208,189,169,225,152,
    0x5,'Q',161,'M','7',162,131,'y',206,141,29,'*',228,132,'0',10,6,8,'*',134,
    'H',0xce,'=',4,3,3,3,'g',0,'0','d',2,'0','%',164,129,'E',2,'k',18,'K','u',
    't','O',0xc8,'#',0xe3,'p',242,'u','r',222,'|',137,240,207,145,'r','a',158,
    '^',16,146,'Y','V',185,131,199,16,231,'8',233,'X','&','6','}',213,228,'4',
    134,'9',2,'0','|','6','S',240,'0',229,'b','c',':',153,226,182,163,';',155,
    '4',0xfa,30,218,16,146,'q','^',145,19,167,221,164,'n',146,204,'2',214,245,
    '!','f',199,'/',234,150,'c','j','e','E',146,149,1,180,
]
