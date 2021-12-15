// Copyright (C) 2019 Toitware ApS. All rights reserved.

import expect show *

import http
import tls
import .tcp as tcp
import net.x509 as net

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
  test_site "client.badssl.com" null null false null
  // Disabled until the new keys arrive, see
  // https://github.com/chromium/badssl.com/issues/422
  // test_site "client.badssl.com" PUBLIC PRIVATE true "BadSSL Client Certificate"
  if load_limiter.test_failures:
    throw load_limiter.has_test_failure

test_site url cert key expect_ok expected_cert_name:
  host := url
  port := 443
  if (url.index_of ":") != -1:
    array := url.split ":"
    host = array[0]
    port = int.parse array[1]
  load_limiter.inc
  if expect_ok:
    task:: working_site host port cert key expected_cert_name
  else:
    task:: non_working_site host port cert key expected_cert_name

non_working_site site port cert key expected_cert_name:
  exception ::= catch:
    connect_to_site site port cert key expected_cert_name
    load_limiter.log_test_failure "*** Incorrectly failed to reject SSL connection to $site ***"
  load_limiter.dec

working_site host port cert key expected_cert_name:
  error := true
  try:
    connect_to_site host port cert key expected_cert_name
    error = false
  finally:
    if error:
      load_limiter.log_test_failure "*** Incorrectly failed to connected to $host ***"
    load_limiter.dec

connect_to_site host port cert key expected_cert_name:
  raw := tcp.TcpSocket
  raw.connect host port
  socket := tls.Socket.client raw
    --server_name=host
    --root_certificates=net.TRUSTED_ROOTS
    --certificate=key ? tls.Certificate cert key : null

  expect_equals cert.common_name expected_cert_name

  connection := http.Connection socket host

  request := connection.new_request "GET" "/"

  response := request.send

  status := response.status_code

  if 400 <= status < 600:
    socket.close
    error := "Status code  $status"
    throw error

  bytes := 0

  while data := response.read:
    bytes += data.size

  connection.close

  print "Read $bytes bytes from https://$host$(port == 443 ? "" : ":$port")/"

PUBLIC ::= net.Certificate.parse """\
subject=/C=US/ST=California/L=San Francisco/O=BadSSL/CN=BadSSL Client Certificate
issuer=/C=US/ST=California/L=San Francisco/O=BadSSL/CN=BadSSL Client Root Certificate Authority
-----BEGIN CERTIFICATE-----
MIIEnTCCAoWgAwIBAgIJAPC7KMFjfslXMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNV
BAYTAlVTMRMwEQYDVQQIDApDYWxpZm9ybmlhMRYwFAYDVQQHDA1TYW4gRnJhbmNp
c2NvMQ8wDQYDVQQKDAZCYWRTU0wxMTAvBgNVBAMMKEJhZFNTTCBDbGllbnQgUm9v
dCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkwHhcNMTcxMTE2MDUzNjMzWhcNMTkxMTE2
MDUzNjMzWjBvMQswCQYDVQQGEwJVUzETMBEGA1UECAwKQ2FsaWZvcm5pYTEWMBQG
A1UEBwwNU2FuIEZyYW5jaXNjbzEPMA0GA1UECgwGQmFkU1NMMSIwIAYDVQQDDBlC
YWRTU0wgQ2xpZW50IENlcnRpZmljYXRlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A
MIIBCgKCAQEAxzdfEeseTs/rukjly6MSLHM+Rh0enA3Ai4Mj2sdl31x3SbPoen08
utVhjPmlxIUdkiMG4+ffe7N+JtDLG75CaxZp9CxytX7kywooRBJsRnQhmQPca8MR
WAJBIz+w/L+3AFkTIqWBfyT+1VO8TVKPkEpGdLDovZOmzZAASi9/sj+j6gM7AaCi
DeZTf2ES66abA5pOp60Q6OEdwg/vCUJfarhKDpi9tj3P6qToy9Y4DiBUhOct4MG8
w5XwmKAC+Vfm8tb7tMiUoU0yvKKOcL6YXBXxB2kPcOYxYNobXavfVBEdwSrjQ7i/
s3o6hkGQlm9F7JPEuVgbl/Jdwa64OYIqjQIDAQABoy0wKzAJBgNVHRMEAjAAMBEG
CWCGSAGG+EIBAQQEAwIHgDALBgNVHQ8EBAMCBeAwDQYJKoZIhvcNAQELBQADggIB
AKpzk1ZTunWuof3DIer2Abq7IV3STGeFaoH4TuHdSbmXwC0KuPkv7wVPgPekyRaH
b9CBnsreRF7eleD1M63kakhdnA1XIbdJw8sfSDlKdI4emmb4fzdaaPxbrkQ5IxOB
QDw5rTUFVPPqFWw1bGP2zrKD1/i1pxUtGM0xem1jR7UZYpsSPs0JCOHKZOmk8OEW
Uy+Jp4gRzbMLZ0TrvajGEZXRepjOkXObR81xZGtvTNP2wl1zm13ffwIYdqJUrf1H
H4miU9lVX+3/Z+2mVHBWhzBgbTmo06s3uwUE6JsxUGm2/w4NNblRit0uQcGw7ba8
kl2d5rZQscFsqNFz2vRjj1G0dO8S3owmuF0izZO9Fqvq0jB6oaUkxcAcTKFSjs2z
wy1oy+cu8iO3GRbfAW7U0xzGp9MnkdPS5dHzvhod3/DK0YVskfxZF7M8GhkjT7Qm
2EUBQNNMNXC3g/GXTdXOgqqjW5GXahI8Z6Q4OYN6xZwuEhizwKkgojwaww2YgYT9
MJXciJZWr3QXvFdBH7m0zwpKgQ1wm6j3yeyuRphq2lEtU3OQl55A3tXtvqyMXsxk
xMCCNQdmKQt0WYmMS3Xj/AfAY2sjCWziDflvW5mGCUjSYdZ+r3JIIF4m/FNCIO1d
Ioacp9qb0qL9duFlVHtFiPgoKrEdJaNVUL7NG9ppF8pR
-----END CERTIFICATE-----"""

// This key is downloaded from badssl.com for use in testing.
// The original was encrypted with the password "badssl.com",
// but we want to secure our private keys in other ways, so
// this is the decrypted version generated with:
// $ openssl rsa -in private-badssl-key.pem
PRIVATE ::= """\
-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEAxzdfEeseTs/rukjly6MSLHM+Rh0enA3Ai4Mj2sdl31x3SbPo
en08utVhjPmlxIUdkiMG4+ffe7N+JtDLG75CaxZp9CxytX7kywooRBJsRnQhmQPc
a8MRWAJBIz+w/L+3AFkTIqWBfyT+1VO8TVKPkEpGdLDovZOmzZAASi9/sj+j6gM7
AaCiDeZTf2ES66abA5pOp60Q6OEdwg/vCUJfarhKDpi9tj3P6qToy9Y4DiBUhOct
4MG8w5XwmKAC+Vfm8tb7tMiUoU0yvKKOcL6YXBXxB2kPcOYxYNobXavfVBEdwSrj
Q7i/s3o6hkGQlm9F7JPEuVgbl/Jdwa64OYIqjQIDAQABAoIBAFUQf7fW/YoJnk5c
8kKRzyDL1Lt7k6Zu+NiZlqXEnutRQF5oQ8yJzXS5yH25296eOJI+AqMuT28ypZtN
bGzcQOAZIgTxNcnp9Sf9nlPyyekLjY0Y6PXaxX0e+VFj0N8bvbiYUGNq6HCyC15r
8uvRZRvnm04YfEj20zLTWkxTG+OwJ6ZNha1vfq8z7MG5JTsZbP0g7e/LrEb3wI7J
Zu9yHQUzq23HhfhpmLN/0l89YLtOaS8WNq4QvKYgZapw/0G1wWoWW4Y2/UpAxZ9r
cqTBWSpCSCCgyWjiNhPbSJWfe/9J2bcanITLcvCLlPWGAHy1wpo9iBH57y7S+7YS
3yi7lgECgYEA8lwaRIChc38tmtQCNPtai/7uVDdeJe0uv8Jsg04FTF8KMYcD0V1g
+T7rUPA+rTHwv8uAGLdzl4NW5Qryw18rDY+UivnaZkEdEsnlo3fc8MSQF78dDHCX
nwmHfOmBnBoSbLl+W5ByHkJRHOnX+8qKq9ePNFUMf/hZNYuma9BCFBUCgYEA0m2p
VDn12YdhFUUBIH91aD5cQIsBhkHFU4vqW4zBt6TsJpFciWbrBrTeRzeDou59aIsn
zGBrLMykOY+EwwRku9KTVM4U791Z/NFbH89GqyUaicb4or+BXw5rGF8DmzSsDo0f
ixJ9TVD5DmDi3c9ZQ7ljrtdSxPdA8kOoYPFsApkCgYEA08uZSPQAI6aoe/16UEK4
Rk9qhz47kHlNuVZ27ehoyOzlQ5Lxyy0HacmKaxkILOLPuUxljTQEWAv3DAIdVI7+
WMN41Fq0eVe9yIWXoNtGwUGFirsA77YVSm5RcN++3GQMZedUfUAl+juKFvJkRS4j
MTkXdGw+mDa3/wsjTGSa2mECgYABO6NCWxSVsbVf6oeXKSgG9FaWCjp4DuqZErjM
0IZSDSVVFIT2SSQXZffncuvSiJMziZ0yFV6LZKeRrsWYXu44K4Oxe4Oj5Cgi0xc1
mIFRf2YoaIIMchLP+8Wk3ummfyiC7VDB/9m8Gj1bWDX8FrrvKqbq31gcz1YSFVNn
PgLkAQKBgFzG8NdL8os55YcjBcOZMUs5QTKiQSyZM0Abab17k9JaqsU0jQtzeFsY
FTiwh2uh6l4gdO/dGC/P0Vrp7F05NnO7oE4T+ojDzVQMnFpCBeL7x08GfUQkphEG
m0Wqhhi8/24Sy934t5Txgkfoltg8ahkx934WjP6WWRnSAu+cf+vW
-----END RSA PRIVATE KEY-----"""
