// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import monitor
import net
import net.x509 as net
import tls

main:
  network := net.open
  certificate := tls.Certificate SERVER-CERTIFICATE SERVER-KEY
  socket := network.tcp-listen 0
  port := socket.local-address.port

  server-task := task::
    while true:
      e := catch:
        client := socket.accept
        tls-socket/tls.Socket? := null
        try:
          tls-socket = tls.Socket.server client --certificate=certificate
          tls-socket.out.write "OK"
        finally:
          if tls-socket:
            tls-socket.close
          else:
            client.close

  expect-throw-pattern "unknown root certificate":
    client-socket := network.tcp-connect "localhost" port
    try:
      client-tls-socket := tls.Socket.client client-socket
      message := client-tls-socket.in.read
    finally:
      client-socket.close

  // We can skip the verification.
  client-socket := network.tcp-connect "localhost" port
  client-tls-socket := tls.Socket.client client-socket --skip-certificate-verification
  message := client-tls-socket.in.read
  expect-equals "OK" message.to-string
  client-socket.close

  (tls.RootCertificate SERVER-CERTIFICATE-RAW).install
  client-socket = network.tcp-connect "localhost" port
  client-tls-socket = tls.Socket.client client-socket --server-name="localhost"
  message = client-tls-socket.in.read
  expect-equals "OK" message.to-string
  client-socket.close

  server-task.cancel
  socket.close
  network.close

expect-throw-pattern pattern [block]:
  e := catch block
  expect-not-null e
  expect (e.to-ascii-lower.contains pattern.to-ascii-lower)

SERVER-CERTIFICATE ::= net.Certificate.parse SERVER-CERTIFICATE-RAW

SERVER-CERTIFICATE-RAW ::= """
-----BEGIN CERTIFICATE-----
MIIDazCCAlOgAwIBAgIUS0C+yu7saxTY1ymliiYzjY4/lW0wDQYJKoZIhvcNAQEL
BQAwRTELMAkGA1UEBhMCREsxEzARBgNVBAgMClNvbWUtU3RhdGUxDTALBgNVBAoM
BFRvaXQxEjAQBgNVBAMMCWxvY2FsaG9zdDAeFw0yNTAzMDcwOTU4NTNaFw0yNTA0
MDYwOTU4NTNaMEUxCzAJBgNVBAYTAkRLMRMwEQYDVQQIDApTb21lLVN0YXRlMQ0w
CwYDVQQKDARUb2l0MRIwEAYDVQQDDAlsb2NhbGhvc3QwggEiMA0GCSqGSIb3DQEB
AQUAA4IBDwAwggEKAoIBAQChLsw2anjvaKTpjzJHJrbkKqfTCNReVisi7kXb0Ihy
abr66Nj99SEUcLbP6zkw52yOPJ88IxuIsW47YfKt7uj01ntRc8Og/WfHmxTiOBEj
v9rD2OdC6tJoSsjnZGTAQllIk0hB0GfFfC3zKRIhMSuLpefm6oQZAOiRIcx8E0vn
vcIhchtTfTyU9FTWPpH8q256FQaC/kJzjGWGSvqrfdP/J8CLkXYr2OK/CGvdNeKR
1xzZ1B6VBHDFx7JYxj0XcRakxEaUB7bEyMJS5B/PZ0A2dLakgq0sGgeyM6Dy3+Aq
zyZUC2d+d93iOzCkmBsEFfQRwiUnclfItMHcZFTNIVp7AgMBAAGjUzBRMB0GA1Ud
DgQWBBQJMfPLsx5BUxMED3XrHlMBJVQHKjAfBgNVHSMEGDAWgBQJMfPLsx5BUxME
D3XrHlMBJVQHKjAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQCJ
4aWuFkiCp+lVfZN8FQd9JCf/ZvoV6gDusWlfMvfs97++MbgmpkZWH2YaRNUmpgQF
pvAspDr9rygVCHHTXH7qz2qdRuz+suTq/gYtnJIlACMu0zXmZzYGr8Vq+8fNUhSP
kUxv77wRC476iONE9+ttR+7LjMpqE8DOLxLmidzHFUPuYoA3JsXK5DaTEJqa6BjQ
eVwkOFL/ZBVCXKlgw+BLOHda/f92iPxGDoFavwOPwwAhb+2ecUIsDq8sCH8/gr6l
S8QB/tJVtaPlh0Llrakl/wGWlI0qkLUbaoxbrTzJLkohQGdfKoImKNUpLk4OvGfb
0WhPFOtT8KXXKocy8b3U
-----END CERTIFICATE-----
"""

SERVER-KEY ::= """
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQChLsw2anjvaKTp
jzJHJrbkKqfTCNReVisi7kXb0Ihyabr66Nj99SEUcLbP6zkw52yOPJ88IxuIsW47
YfKt7uj01ntRc8Og/WfHmxTiOBEjv9rD2OdC6tJoSsjnZGTAQllIk0hB0GfFfC3z
KRIhMSuLpefm6oQZAOiRIcx8E0vnvcIhchtTfTyU9FTWPpH8q256FQaC/kJzjGWG
SvqrfdP/J8CLkXYr2OK/CGvdNeKR1xzZ1B6VBHDFx7JYxj0XcRakxEaUB7bEyMJS
5B/PZ0A2dLakgq0sGgeyM6Dy3+AqzyZUC2d+d93iOzCkmBsEFfQRwiUnclfItMHc
ZFTNIVp7AgMBAAECggEADv0ZfTxZeRBaHzFALUdEXeNsx9f1jiNyAqv1tlAMeddE
zaBpmidf2ohaXh6Zqudab1lKO+Vn4hMRFSSYOxeq28A2QSGd+sXJDzhn4/S8Y0t4
17PyWlHlglB+1KwmHyel9dtix/wBXZpp2Eexdk5RDL0MDt7JrSmQdvticKDt8uOX
5AUNwHK09Fu9GOa/6Z6RtZ67IUnKff6P4tGw9pxWyobZK2mIIuGyYM7mw6zdrtkZ
DtIkK7j75gz3pkejX8DoFaQNgTjN6TSnBI5hjkmOeY4zP7WE4o9bp3LE8zEUaiKs
6rSXZQUWibsRQUVNsdoU9EWxLJrb3VNO1tF8vK+JQQKBgQDYSzHVFeUkesJ16Tzn
AlRttHMeXvr+qRqkSY0VaRAlmsdxc+r8Popa2DvGmFzLw5fXnZ/MJdxnwptmRxe8
uyJsaJ19M4b2ca92wPN15HSuaPoi42DYjT7GJBh+bZYg2Fh7vSRUTRgRonfMElET
DopXYv2QXd0+yypktY0cSJDIJwKBgQC+xaTyVYBYDr14cD0uW0CMujA5dopl8S4H
nVKJtTNiseaBRRrNA4sRLAnS7iFILs+SmK8wcue7W+uJbdr93aPCOPQLwn9xicRE
IFTRTtL7l/xKcyMdvallBkZvOY8OfnTkOwgNv5owCYZxbYHh9Ecb2DEqB6YU8zma
5Riq6uEbjQKBgQC8H0K7a+y9+sux1Gf1IJCgTkemDcROxHP4mkRMb/HsUx/O7Jxg
QmEBvHrZM2HalEc38M+wtulpkdipb4IU08qP8bmw0KU9KgoLxqy6SDa4D3Qn7g4o
q0kC+xgWtmfSL3lePlcfv2IEzINXikLbyVTHxsB11T3+RKSdrU6LYA4VFwKBgHA2
Z3iXrF+fg/lU49fhmw1r8zPJs0yVWcLm2gbgS7Jw/CnrkQEoZWObaMfmhDMmPbh4
EQxJel8tiVUUBi0vcsSqpXpJVJdfNs/vyJQ5bkbJNoBAS1aSGhKvZzzDOY+H+I/K
3Ujg+/vnjmonxK849Z6+QuT7DMjj7G1c9m6KrBB9AoGBAKeiS1BEo7PICQNllxDK
KPDSPux0fWPy5SSZ1gaA74rNbKCYfupXe22aCwEFivPZe0MfhmmLgHmfsLP1CxDg
fRx7tFFh2Hl4zEsJkrvFXcqVwYDEqmBUcV7V4GQiIldGBlKwMCx/pdLPKbA5UCIN
Kqu+oUotz8/E70hcqDRGsjy2
-----END PRIVATE KEY-----
"""
