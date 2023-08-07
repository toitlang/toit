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
  error := catch code
  expect: error.contains name

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
    "dmi.dk",
    "pravda.ru",
    "elpriser.nu",
    "coinbase.com",
    "helsinki.fi",
    "lund.se",
    "web.whatsapp.com",
    "digimedia.com",
    ]
  non_working := [
    "$(dns_lookup "amazon.com")",   // This fails because the name we use to connect (an IP address string) doesn't match the cert name.
    "wrong.host.badssl.com/Common Name|unknown root cert",
    "self-signed.badssl.com/Certificate verification failed|unknown root cert",
    "untrusted-root.badssl.com/Certificate verification failed|unknown root cert",
    "captive-portal.badssl.com",
    "mitm-software.badssl.com",
    "european-union.europa.eu/Starfield",  // Relies on unknown Starfield Tech root.
    "elpais.es/Starfield",                 // Relies on unknown Starfield Tech root.
    "vw.de/Starfield",                     // Relies on unknown Starfield Tech root.
    "moxie.org/Starfield",                 // Relies on unknown Starfield Tech root.
    "signal.org/Starfield",                // Relies on unknown Starfield Tech root.
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
  tls.add_global_root_certificate_ DIGICERT_GLOBAL_ROOT_G2_BYTES 0x025449c2
  tls.add_global_root_certificate_ DIGICERT_GLOBAL_ROOT_CA_BYTES
  // Test roots that are RootCertificate objects.
  GLOBALSIGN_ROOT_CA_BYTES.install  // Needed for pravda.ru.
  GLOBALSIGN_ROOT_CA_R3_BYTES.install  // Needed for lund.se.
  COMODO_RSA_CERTIFICATION_AUTHORITY_BYTES.install  // Needed for elpriser.nu.
  BALTIMORE_CYBERTRUST_ROOT_BYTES.install  // Needed for coinbase.com.
  // Test a binary root that is a modified copy-on-write byte array.
  USERTRUST_ECC_CERTIFICATION_AUTHORITY_BYTES[42] ^= 42
  USERTRUST_ECC_CERTIFICATION_AUTHORITY_BYTES[42] ^= 42
  tls.add_global_root_certificate_ USERTRUST_ECC_CERTIFICATION_AUTHORITY_BYTES  // Needed for helsinki.fi.
  // Test ASCII (PEM) roots.
  tls.add_global_root_certificate_ USERTRUST_RSA_CERTIFICATE_TEXT 0x0c49cbaf  // Needed for dmi.dk.
  tls.add_global_root_certificate_ ISRG_ROOT_X1_TEXT  // Needed by dkhostmaster.dk and digimedia.com.
  // Test that the cert can be a slice.
  tls.add_global_root_certificate_ DIGICERT_ROOT_TEXT[..DIGICERT_ROOT_TEXT.size - 9]

  // Test that we get a sensible error when trying to add a parsed root
  // certificate.
  parsed := net.Certificate.parse USERTRUST_RSA_CERTIFICATE_TEXT
  expect_error "WRONG_OBJECT_TYPE": tls.add_global_root_certificate_ parsed

  // Test that unparseable cert gives an immediate error.
  expect_error "OID is not found":
    DIGICERT_GLOBAL_ROOT_CA_BYTES[42] ^= 42
    tls.add_global_root_certificate_ DIGICERT_GLOBAL_ROOT_CA_BYTES

  // Test that it's not too costly to add the same cert multiple times.
  1_000_000.repeat:
    tls.add_global_root_certificate_ DIGICERT_GLOBAL_ROOT_G2_BYTES 0x025449c2

// Ebay.de sometimes uses this trusted root certificate.
// Serial number 01:FD:6D:30:FC:A3:CA:51:A8:1B:BC:64:0E:35:03:2D
USERTRUST_RSA_CERTIFICATE_TEXT ::= """\
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

GLOBALSIGN_ROOT_CA_BYTES ::= tls.RootCertificate #[
    '0',0x82,3,'u','0',0x82,2,']',160,3,2,1,2,2,11,4,0,0,0,0,1,21,'K','Z',195,
    0x94,'0',13,6,9,'*',134,'H',134,247,13,1,1,5,5,0,'0','W','1',11,'0',9,6,3,
    'U',4,6,19,2,'B','E','1',25,'0',23,6,3,'U',4,10,19,16,'G','l','o','b','a',
    'l','S','i','g','n',' ','n','v','-','s','a','1',16,'0',14,6,3,'U',4,11,19,
    7,'R','o','o','t',' ','C','A','1',27,'0',25,6,3,'U',4,3,19,18,'G','l','o',
    'b','a','l','S','i','g','n',' ','R','o','o','t',' ','C','A','0',30,23,0xd,
    '9','8','0','9','0','1','1','2','0','0','0','0','Z',23,13,'2','8','0','1',
    '2','8','1','2','0','0','0','0','Z','0','W','1',11,'0',9,6,3,'U',4,6,19,2,
    'B','E','1',25,'0',23,6,3,'U',4,0xa,19,16,'G','l','o','b','a','l','S','i',
    'g','n',' ','n','v','-','s','a','1',0x10,'0',14,6,3,'U',4,11,19,7,'R','o',
    'o','t',' ','C','A','1',0x1b,'0',25,6,3,'U',4,3,19,18,'G','l','o','b','a',
    'l','S','i','g','n',' ','R','o','o','t',' ','C','A','0',0x82,1,'"','0',13,
    6,9,'*',0x86,'H',134,247,13,1,1,1,5,0,3,130,1,15,0,'0',130,1,10,2,130,1,1,
    0,0xda,14,230,153,141,206,163,227,'O',138,'~',251,241,139,131,'%','k',234,
    'H',0x1f,0xf1,'*',176,185,149,17,4,189,240,'c',209,226,'g','f',207,28,221,
    207,27,'H','+',238,141,137,142,154,175,')',128,'e',171,233,199,'-',18,203,
    0xab,28,'L','p',7,161,'=',10,'0',205,21,141,'O',248,221,212,140,'P',21,28,
    0xef,'P',0xee,196,'.',247,252,233,'R',242,145,'}',224,'m',213,'5','0',142,
    '^','C','s',242,'A',233,213,'j',227,178,137,':','V','9','8','o',6,'<',136,
    'i','[','*','M',0xc5,0xa7,'T',184,'l',137,204,155,249,'<',202,229,253,137,
    0xf5,0x12,'<',146,'x',150,214,220,'t','n',147,'D','a',209,141,199,'F',178,
    'u',0x0e,134,232,25,138,213,'m','l',213,'x',22,149,162,233,200,10,'8',235,
    242,'$',19,'O','s','T',147,19,133,':',27,188,30,'4',181,139,5,140,185,'w',
    0x8b,177,219,31,' ',145,171,9,'S','n',144,206,'{','7','t',185,'p','G',145,
    '"','Q','c',0x16,'y',174,177,174,'A','&',8,200,25,'+',209,'F',170,'H',214,
    'd','*',0xd7,131,'4',255,',','*',193,'l',25,'C','J',7,133,231,211,'|',246,
    '!','h',239,234,242,'R',159,127,147,144,207,2,3,1,0,1,163,'B','0','@','0',
    14,6,3,'U',29,15,1,1,255,4,4,3,2,1,6,'0',15,6,3,'U',29,19,1,1,255,4,5,'0',
    0x03,1,1,255,'0',29,6,3,'U',29,14,4,22,4,20,'`','{','f',26,'E',13,151,202,
    0x89,'P','/','}',4,205,'4',168,255,252,253,'K','0',13,6,9,'*',134,'H',134,
    0xf7,13,1,1,5,5,0,3,130,1,1,0,214,'s',231,'|','O','v',208,141,191,236,186,
    162,190,'4',197,'(','2',181,'|',252,'l',156,',','+',189,9,158,'S',191,'k',
    '^',0xaa,0x11,'H',182,229,8,163,179,202,'=','a','M',211,'F',9,179,'>',195,
    0xa0,0xe3,'c','U',27,0xf2,186,239,173,'9',225,'C',185,'8',163,230,'/',138,
    '&',';',239,160,'P','V',249,198,10,253,'8',205,196,11,'p','Q',148,151,152,
    4,223,195,'_',148,213,21,201,20,'A',156,196,']','u','d',21,13,255,'U','0',
    236,134,143,255,13,239,',',185,'c','F',246,170,252,223,188,'i',253,'.',18,
    'H','d',0x9a,0xe0,0x95,240,166,239,')',143,1,177,21,181,12,29,165,254,'i',
    ',','i','$','x',30,0xb3,167,28,'q','b',238,202,200,151,172,23,']',138,194,
    0xf8,'G',0x86,'n','*',196,'V','1',149,208,'g',137,133,'+',249,'l',166,']',
    'F',157,12,170,130,228,153,'Q',221,'p',183,219,'V','=','a',228,'j',225,92,
    214,246,254,'=',222,'A',204,7,174,'c','R',191,'S','S',244,'+',233,199,253,
    182,247,130,'_',133,210,'A',24,219,129,179,4,28,197,31,164,128,'o',21,' ',
    201,222,12,136,10,29,214,'f','U',226,252,'H',201,')','&','i',224,
]

COMODO_RSA_CERTIFICATION_AUTHORITY_BYTES ::= tls.RootCertificate #[
    '0',0x82,5,216,'0',130,3,192,160,3,2,1,2,2,16,'L',170,249,202,219,'c','o',
    224,31,247,'N',216,'[',3,134,157,'0',13,6,9,'*',134,'H',134,247,13,1,1,12,
    0x5,0,'0',129,133,'1',11,'0',9,6,3,'U',4,6,19,2,'G','B','1',27,'0',25,6,3,
    'U',4,8,19,18,'G','r','e','a','t','e','r',' ','M','a','n','c','h','e','s',
    't','e','r','1',0x10,'0',0xe,6,3,'U',4,7,19,7,'S','a','l','f','o','r','d',
    '1',26,'0',24,6,3,'U',4,0xa,19,17,'C','O','M','O','D','O',' ','C','A',' ',
    'L','i','m','i','t','e','d','1','+','0',')',0x06,3,'U',4,3,19,'"','C','O',
    'M','O','D','O',' ','R','S','A',' ','C','e','r','t','i','f','i','c','a',
    't','i','o','n',' ','A','u','t','h','o','r','i','t','y','0',30,23,0xd,'1',
    '0','0','1','1','9','0','0','0','0','0','0','Z',23,13,'3','8','0','1','1',
    '8','2','3','5','9','5','9','Z','0',129,133,'1',11,'0',9,6,3,'U',4,6,19,2,
    'G','B','1',0x1b,'0',25,6,3,'U',4,8,19,18,'G','r','e','a','t','e','r',' ',
    'M','a','n','c','h','e','s','t','e','r','1',0x10,'0',0xe,6,3,'U',4,7,19,7,
    'S','a','l','f','o','r','d','1',26,'0',24,6,3,'U',4,0xa,19,17,'C','O','M',
    'O','D','O',' ','C','A',' ','L','i','m','i','t','e','d','1','+','0',')',6,
    3,'U',4,3,19,'"','C','O','M','O','D','O',' ','R','S','A',' ','C','e','r',
    't','i','f','i','c','a','t','i','o','n',' ','A','u','t','h','o','r','i',
    't','y','0',130,2,'"','0',13,6,9,'*',134,'H',134,247,13,1,1,1,5,0,3,130,2,
    0x0f,0,'0',130,2,10,2,130,2,1,0,145,232,'T',146,210,10,'V',177,172,13,'$',
    221,197,207,'D','g','t',153,'+','7',163,'}','#','p',0,'q',188,'S',223,196,
    0xfa,'*',18,0x8f,'K',127,16,'V',189,159,'p','r',183,'a',127,201,'K',15,23,
    0xa7,'=',0xe3,0xb0,4,'a',238,255,17,151,199,244,134,'>',10,250,'>',92,249,
    0x93,0xe6,'4','z',0xd9,20,'k',231,156,179,133,160,130,'z','v',175,'q',144,
    215,236,253,13,250,156,'l',250,223,176,130,244,20,'~',249,190,196,166,'/',
    'O',0x7f,153,127,181,252,'g','C','r',189,12,0,214,137,235,'k',',',211,237,
    143,152,28,20,171,'~',229,227,'n',252,216,168,228,146,'$',218,'C','k','b',
    0xb8,'U',0xfd,0xea,193,188,'l',182,139,243,14,141,154,228,155,'l','i',153,
    248,'x','H','0','E',213,173,225,13,'<','E','`',252,'2',150,'Q',39,188,'g',
    0xc3,202,'.',182,'k',234,'F',199,199,' ',160,177,31,'e',222,'H',8,186,164,
    'N',0xa9,0xf2,131,'F','7',132,235,232,204,129,'H','C','g','N','r','*',155,
    0x5c,0xbd,'L',27,'(',138,92,'"','{',180,171,152,217,238,224,'Q',131,195,9,
    'F','N','m','>',153,250,149,23,218,'|','3','W','A','<',141,'Q',237,11,182,
    92,175,',','c',26,223,'W',200,'?',188,233,']',196,155,175,'E',153,226,163,
    'Z','$',0xb4,0xba,169,'V','=',207,'o',170,255,'I','X',190,240,168,255,244,
    184,173,233,'7',251,186,184,244,11,':',249,232,'C','B',30,137,216,132,203,
    0x13,241,217,187,225,137,'`',184,140,'(','V',172,20,29,156,10,231,'q',235,
    0xcf,14,221,'=',169,150,161,'H',189,'<',247,175,181,13,'"','L',192,17,129,
    236,'V',';',246,211,162,226,'[',183,178,4,'"','R',149,128,147,'i',232,142,
    'L','e',0xf1,145,3,'-','p','t',2,234,139,'g',21,')','i','R',2,187,215,223,
    'P','j','U','F',0xbf,0xa0,163,'(','a',127,'p',208,195,162,170,',','!',170,
    'G',0xce,'(',0x9c,6,'E','v',191,130,24,39,180,213,174,180,203,'P',230,'k',
    0xf4,'L',0x86,'q','0',0xe9,166,223,22,134,224,216,255,'@',221,251,208,'B',
    0x88,0x7f,163,'3',':','.',92,30,'A',17,129,'c',206,24,'q','k','+',236,166,
    138,183,'1',92,':','j','G',224,195,'y','Y',214,' ',26,175,242,'j',152,170,
    'r',188,'W','J',210,'K',157,187,16,252,176,'L','A',229,237,29,'=','^','(',
    157,156,204,191,179,'Q',218,167,'G',229,132,'S',2,3,1,0,1,163,'B','0','@',
    '0',29,6,3,'U',29,0xe,4,22,4,20,187,175,'~',2,'=',250,166,241,'<',132,142,
    0xad,238,'8',152,236,217,'2','2',212,'0',14,6,3,'U',29,15,1,1,255,4,4,3,2,
    1,6,'0',15,6,3,'U',29,19,1,1,255,4,5,'0',3,1,1,255,'0',13,6,9,'*',134,'H',
    0x86,247,13,1,1,12,5,0,3,130,2,1,0,10,241,213,'F',132,183,174,'Q',187,'l',
    0xb2,'M','A',0x14,0,147,'L',156,203,229,192,'T',207,160,'%',142,2,249,253,
    0xb0,162,13,245,' ',152,'<',19,'-',172,'V',162,176,214,'~',17,146,233,'.',
    0xba,158,'.',154,'r',177,189,25,'D','l','a','5',162,154,180,22,18,'i','Z',
    140,225,215,'>',164,26,232,'/',3,244,174,'a',29,16,27,'*',164,139,'z',197,
    0xfe,5,0xa6,225,192,214,200,254,158,174,143,'+',186,'=',153,248,216,'s',9,
    'X','F','n',166,156,244,215,39,211,149,218,'7',131,'r',28,211,'s',224,162,
    'G',0x99,3,'8',']',0xd5,'I','y',0,')',28,199,236,155,' ',28,7,'$','i','W',
    'x',0xb2,'9',0xfc,':',0x84,160,181,156,'|',141,191,'.',147,'b',39,183,'9',
    0xda,23,24,0xae,189,'<',9,'h',255,132,155,'<',213,214,11,3,227,'W',158,20,
    247,209,235,'O',200,189,135,'#',183,182,'I','C','y',133,92,186,235,146,11,
    161,198,232,'h',168,'L',22,177,26,153,10,232,'S',',',146,187,161,9,24,'u',
    0xc,'e',168,'{',203,'#',183,26,194,'(',133,195,27,255,208,'+','b',239,164,
    '{',0x09,145,152,'g',140,20,1,205,'h',6,'j','c','!','u',3,128,136,138,'n',
    0x81,0xc6,0x85,242,169,164,'-',231,244,165,'$',16,'G',131,202,205,244,141,
    'y','X',0xb1,6,155,231,26,'*',217,157,1,215,148,'}',237,3,'J',202,240,219,
    0xe8,0xa9,1,'>',0xf5,'V',153,201,30,142,'I','=',187,229,9,185,224,'O','I',
    146,'=',22,130,'@',204,204,'Y',198,230,':',237,18,'.','i','<','l',149,177,
    0xfd,0xaa,29,'{',127,134,190,30,14,'2','F',251,251,19,143,'u',127,'L',139,
    'K','F','c',0xfe,0,'4','@','p',0xc1,195,185,161,221,166,'p',226,4,179,'A',
    0xbc,233,128,145,234,'d',156,'z',225,'"',3,169,156,'n','o',14,'e','O','l',
    0x87,0x87,'^',0xf3,'n',160,249,'u',165,155,'@',232,'S',178,39,157,'J',185,
    192,'w','!',141,255,135,242,222,188,140,239,23,223,183,'I',11,209,242,'n',
    '0',0x0b,26,0xe,'N','v',237,17,252,245,233,'V',178,'}',191,199,'m',10,147,
    140,165,208,192,182,29,190,':','N',148,162,215,'n','l',11,194,138,'|',250,
    ' ',243,196,228,229,205,13,168,203,145,146,177,'|',133,236,181,20,'i','f',
    0xe,130,231,205,206,200,'-',166,'Q',127,'!',193,'5','S',133,6,'J',']',159,
    173,187,27,'_','t',
]

BALTIMORE_CYBERTRUST_ROOT_BYTES ::= tls.RootCertificate #[
    '0',0x82,3,'w','0',130,2,'_',160,3,2,1,2,2,4,2,0,0,185,'0',13,6,9,'*',134,
    'H',0x86,0xf7,0xd,1,1,5,5,0,'0','Z','1',11,'0',9,6,3,'U',4,6,19,2,'I','E',
    '1',0x12,'0',16,6,3,'U',4,10,19,9,'B','a','l','t','i','m','o','r','e','1',
    19,'0',17,6,3,'U',4,0xb,19,10,'C','y','b','e','r','T','r','u','s','t','1',
    '"','0',' ',6,3,'U',4,3,19,25,'B','a','l','t','i','m','o','r','e',' ','C',
    'y','b','e','r','T','r','u','s','t',' ','R','o','o','t','0',30,23,0xd,'0',
    '0','0','5','1','2','1','8','4','6','0','0','Z',23,13,'2','5','0','5','1',
    '2','2','3','5','9','0','0','Z','0','Z','1',11,'0',9,6,3,'U',4,6,19,2,'I',
    'E','1',0x12,'0',16,6,3,'U',4,10,19,9,'B','a','l','t','i','m','o','r','e',
    '1',19,'0',17,6,3,'U',4,0xb,19,10,'C','y','b','e','r','T','r','u','s','t',
    '1','"','0',' ',6,3,'U',4,3,19,25,'B','a','l','t','i','m','o','r','e',' ',
    'C','y','b','e','r','T','r','u','s','t',' ','R','o','o','t','0',130,1,'"',
    '0',0x0d,6,9,'*',134,'H',134,247,13,1,1,1,5,0,3,130,1,15,0,'0',130,1,10,2,
    0x82,1,1,0,0xa3,4,187,'"',171,152,'=','W',232,'&','r',154,181,'y',212,')',
    0xe2,0xe1,232,149,128,177,176,227,'[',142,'+',')',154,'d',223,161,']',237,
    0xb0,0x9,5,'m',219,'(','.',206,'b',162,'b',254,180,136,218,18,235,'8',235,
    '!',0x9d,192,'A','+',1,'R','{',136,'w',211,28,143,199,186,185,136,181,'j',
    0x9,231,'s',232,17,'@',167,209,204,202,'b',141,'-',229,143,11,166,'P',210,
    168,'P',195,'(',234,245,171,'%',135,138,154,150,28,169,'g',184,'?',12,213,
    0xf7,0xf9,'R',19,'/',0xc2,27,213,'p','p',240,143,192,18,202,6,203,154,225,
    0xd9,0xca,'3','z','w',0xd6,248,236,185,241,'h','D','B','H',19,210,192,194,
    0xa4,174,'^','`',254,182,166,5,252,180,221,7,'Y',2,212,'Y',24,152,'c',245,
    0xa5,'c',0xe0,0x90,12,'}',']',178,6,'z',243,133,234,235,212,3,174,'^',132,
    '>','_',0xff,0x15,237,'i',188,249,'9','6','r','u',207,'w','R','M',243,201,
    0x90,',',0xb9,'=',229,201,'#','S','?',31,'$',152,'!',92,7,153,')',189,198,
    ':',0xec,0xe7,'n',0x86,':','k',151,'t','c','3',189,'h',24,'1',240,'x',141,
    'v',0xbf,0xfc,158,142,']','*',134,167,'M',144,220,39,26,'9',2,3,1,0,1,163,
    'E','0','C','0',0x1d,6,3,'U',29,0xe,4,22,4,20,229,157,'Y','0',130,'G','X',
    0xcc,172,250,8,'T','6',134,'{',':',181,4,'M',240,'0',18,6,3,'U',29,19,1,1,
    0xff,4,8,'0',6,1,1,255,2,1,3,'0',14,6,3,'U',29,15,1,1,255,4,4,3,2,1,6,'0',
    0x0d,6,9,'*',0x86,'H',134,247,13,1,1,5,5,0,3,130,1,1,0,133,12,']',142,228,
    'o','Q','h','B',0x05,160,221,187,'O',39,'%',132,3,189,247,'d',253,'-',215,
    '0',227,164,16,23,235,218,')',')',182,'y','?','v',246,25,19,'#',184,16,10,
    0xf9,'X',0xa4,0xd4,'a','p',189,4,'a','j',18,138,23,213,10,189,197,188,'0',
    '|',214,233,12,'%',141,134,'@','O',236,204,163,'~','8',198,'7',17,'O',237,
    221,'h','1',142,'L',210,179,1,'t',238,190,'u','^',7,'H',26,127,'p',255,22,
    92,0x84,192,'y',133,184,5,253,127,190,'e',17,163,15,192,2,180,248,'R','7',
    '9',0x4,213,169,'1','z',24,191,160,'*',244,18,153,247,163,'E',130,227,'<',
    '^',0xf5,157,158,181,200,158,'|','.',200,164,158,'N',8,20,'K','m',253,'p',
    'm','k',26,'c',0xbd,'d',230,31,183,206,240,242,159,'.',187,27,183,242,'P',
    136,'s',146,194,226,227,22,141,154,'2',2,171,142,24,221,233,16,17,238,'~',
    '5',0xab,0x90,0xaf,'>','0',148,'z',208,'3','=',167,'e',15,245,252,142,158,
    'b',0xcf,'G','D',',',1,']',187,29,181,'2',210,'G',210,'8','.',208,254,129,
    0xdc,'2','j',30,181,238,'<',213,252,231,129,29,25,195,'$','B',234,'c','9',
    169,
]

USERTRUST_ECC_CERTIFICATION_AUTHORITY_BYTES ::= #[
    '0',0x82,0x2,143,'0',130,2,21,160,3,2,1,2,2,16,92,139,153,197,'Z',148,197,
    0xd2,'q','V',222,205,137,128,204,'&','0',10,6,8,'*',134,'H',206,'=',4,3,3,
    '0',129,136,'1',11,'0',9,6,3,'U',4,6,19,2,'U','S','1',19,'0',17,6,3,'U',4,
    8,19,10,'N','e','w',' ','J','e','r','s','e','y','1',20,'0',18,6,3,'U',4,7,
    19,11,'J','e','r','s','e','y',' ','C','i','t','y','1',30,'0',28,6,3,'U',4,
    0xa,19,21,'T','h','e',' ','U','S','E','R','T','R','U','S','T',' ','N','e',
    't','w','o','r','k','1','.','0',',',0x06,3,'U',4,3,19,'%','U','S','E','R',
    'T','r','u','s','t',' ','E','C','C',' ','C','e','r','t','i','f','i','c',
    'a','t','i','o','n',' ','A','u','t','h','o','r','i','t','y','0',30,23,0xd,
    '1','0','0','2','0','1','0','0','0','0','0','0','Z',23,13,'3','8','0','1',
    '1','8','2','3','5','9','5','9','Z','0',0x81,136,'1',11,'0',9,6,3,'U',4,6,
    19,2,'U','S','1',19,'0',17,6,3,'U',4,8,19,0xa,'N','e','w',' ','J','e','r',
    's','e','y','1',0x14,'0',18,6,3,'U',4,7,19,11,'J','e','r','s','e','y',' ',
    'C','i','t','y','1',30,'0',28,6,3,'U',4,0xa,19,21,'T','h','e',' ','U','S',
    'E','R','T','R','U','S','T',' ','N','e','t','w','o','r','k','1','.','0',
    ',',0x06,3,'U',4,3,19,'%','U','S','E','R','T','r','u','s','t',' ','E','C',
    'C',' ','C','e','r','t','i','f','i','c','a','t','i','o','n',' ','A','u',
    't','h','o','r','i','t','y','0','v','0',16,6,7,'*',0x86,'H',206,'=',2,1,6,
    0x05,'+',129,4,0,'"',3,'b',0,4,26,172,'T','Z',169,249,'h','#',231,'z',213,
    '$','o','S',0xc6,'Z',0xd8,'K',171,198,213,182,209,230,'s','q',174,221,156,
    214,12,'a',253,219,160,137,3,184,5,20,236,'W',206,238,']','?',226,'!',179,
    0xce,0xf7,212,138,'y',224,163,131,'~','-',151,208,'a',196,241,153,220,'%',
    0x91,'c',0xab,0x7f,'0',163,180,'p',226,199,161,'3',156,243,191,'.',92,'S',
    0xb1,'_',0xb3,'}','2',0x7f,138,'4',227,'y','y',163,'B','0','@','0',29,6,3,
    'U',29,0xe,4,22,4,20,':',225,9,134,212,207,25,194,150,'v','t','I','v',220,
    224,'5',198,'c','c',154,'0',14,6,3,'U',29,15,1,1,255,4,4,3,2,1,6,'0',15,6,
    3,'U',29,19,1,1,0xff,4,5,'0',3,1,1,255,'0',10,6,8,'*',134,'H',206,'=',4,3,
    3,3,'h',0,'0','e',2,'0','6','g',161,22,8,220,228,151,0,'A',29,'N',190,225,
    'c',0x1,207,';',170,'B',17,'d',160,157,148,'9',2,17,'y',92,'{',29,250,'d',
    0xb9,238,22,'B',179,191,138,194,9,196,236,228,177,'M',2,'1',0,233,'*','a',
    'G',0x8c,'R','J','K','N',0x18,'p',246,214,'D',214,'n',245,131,186,'m','X',
    0xbd,'$',0xd9,'V','H',234,239,196,162,'F',129,136,'j',':','F',209,169,155,
    'M',201,'a',218,209,']','W','j',24,
]

GLOBALSIGN_ROOT_CA_R3_BYTES ::= tls.RootCertificate #[
    '0',0x82,0x3,'_','0',130,2,'G',160,3,2,1,2,2,11,4,0,0,0,0,1,'!','X','S',8,
    162,'0',13,6,9,'*',134,'H',134,247,13,1,1,11,5,0,'0','L','1',' ','0',30,6,
    3,'U',4,0xb,19,23,'G','l','o','b','a','l','S','i','g','n',' ','R','o','o',
    't',' ','C','A',' ','-',' ','R','3','1',19,'0',17,6,3,'U',4,0xa,19,10,'G',
    'l','o','b','a','l','S','i','g','n','1',0x13,'0',17,6,3,'U',4,3,19,10,'G',
    'l','o','b','a','l','S','i','g','n','0',30,23,0xd,'0','9','0','3','1','8',
    '1','0','0','0','0','0','Z',23,13,'2','9','0','3','1','8','1','0','0','0',
    '0','0','Z','0','L','1',' ','0',30,6,3,'U',4,11,19,23,'G','l','o','b','a',
    'l','S','i','g','n',' ','R','o','o','t',' ','C','A',' ','-',' ','R','3',
    '1',19,'0',17,6,3,'U',4,0xa,19,10,'G','l','o','b','a','l','S','i','g','n',
    '1',0x13,'0',17,6,3,'U',4,3,19,10,'G','l','o','b','a','l','S','i','g','n',
    '0',0x82,0x1,'"','0',13,6,9,'*',134,'H',134,247,13,1,1,1,5,0,3,130,1,15,0,
    '0',130,1,10,2,130,1,1,0,204,'%','v',144,'y',6,'x','"',22,245,192,131,182,
    0x84,0xca,'(',0x9e,253,5,'v',17,197,173,136,'r',252,'F',2,'C',199,178,138,
    0x9d,4,'_','$',203,'.','K',225,'`',130,'F',225,'R',171,12,129,'G','p','l',
    0xdd,'d',0xd1,235,245,',',163,15,130,'=',12,'+',174,151,215,182,20,134,16,
    'y',0xbb,';',19,0x80,'w',140,8,225,'I',210,'j','b','/',31,'^',250,150,'h',
    0xdf,0x89,39,149,'8',159,6,215,'>',201,203,'&','Y',13,'s',222,176,200,233,
    '&',0x0e,131,21,198,239,'[',139,210,4,'`',202,'I',166,'(',246,'i',';',246,
    0xcb,0xc8,'(',0x91,229,157,138,'a','W','7',172,'t',20,220,'t',224,':',238,
    'r','/','.',0x9c,0xfb,208,187,191,245,'=',0,225,6,'3',232,130,'+',174,'S',
    166,':',22,'s',140,221,'A',14,' ',':',192,180,167,161,233,178,'O',144,'.',
    '2','`',233,'W',203,185,4,146,'h','h',229,'8','&','`','u',178,159,'w',255,
    0x91,0x14,239,174,' ','I',252,173,'@',21,'H',209,2,'1','a',25,'^',184,151,
    239,173,'w',183,'d',154,'z',191,'_',193,19,239,155,'b',251,13,'l',224,'T',
    'i',22,169,3,218,'n',233,131,147,'q','v',198,'i',133,130,23,2,3,1,0,1,163,
    'B','0','@','0',14,6,3,'U',29,15,1,1,255,4,4,3,2,1,6,'0',15,6,3,'U',29,19,
    1,1,0xff,4,5,'0',3,1,1,255,'0',29,6,3,'U',29,14,4,22,4,20,143,240,'K',127,
    168,'.','E','$',174,'M','P',250,'c',154,139,222,226,221,27,188,'0',13,6,9,
    '*',134,'H',134,247,13,1,1,11,5,0,3,130,1,1,0,'K','@',219,192,'P',170,254,
    0xc8,0xc,239,247,150,'T','E','I',187,150,0,9,'A',172,179,19,134,134,'(',7,
    '3',0xca,'k',0xe6,'t',185,186,0,'-',174,164,10,211,245,241,241,15,138,191,
    's','g','J',131,199,'D','{','x',224,175,'n','l','o',3,')',142,'3','9','E',
    0xc3,0x8e,0xe4,185,'W','l',170,252,18,150,236,'S',198,'-',228,'$','l',185,
    0x94,'c',0xfb,220,'S','h','g','V','>',131,184,207,'5','!',195,201,'h',254,
    0xce,0xda,194,'S',170,204,144,138,233,240,']','F',140,149,221,'z','X','(',
    26,'/',29,222,205,0,'7','A',143,237,'D','m',215,'S','(',151,'~',243,'g',4,
    0x1e,21,0xd7,138,150,180,211,222,'L',39,164,'L',27,'s','s','v',244,23,153,
    0xc2,31,'z',0xe,227,'-',8,173,10,28,',',255,'<',171,'U',14,15,145,'~','6',
    0xeb,0xc3,'W','I',0xbe,225,'.','-','|','`',139,195,'A','Q',19,'#',157,206,
    0xf7,'2','k',148,1,168,153,231,',','3',31,':',';','%',210,134,'@',206,';',
    ',',0x86,'x',0xc9,'a','/',20,0xba,238,219,'U','o',223,132,238,5,9,'M',189,
    '(',0xd8,'r',0xce,0xd3,'b','P','e',30,235,146,151,131,'1',217,179,181,202,
    'G','X','?','_',
]
