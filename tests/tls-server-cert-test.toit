// Copyright (C) 2025 Toit contributors
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
  client-tls-socket := tls.Socket.client client-socket --skip-certificate-validation
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

// The following certificate was generated with the following command:
//     openssl req -x509 -newkey rsa:2048 -nodes \
//         -keyout server.key -out server.crt -days 36500 \
//         -subj "/C=DK/ST=State/L=City/O=ToitTest/CN=localhost"

SERVER-CERTIFICATE-RAW ::= """
-----BEGIN CERTIFICATE-----
MIIDiTCCAnGgAwIBAgIUK4YtINjbBlNQX/vS3gYzNXYi2kwwDQYJKoZIhvcNAQEL
BQAwUzELMAkGA1UEBhMCREsxDjAMBgNVBAgMBVN0YXRlMQ0wCwYDVQQHDARDaXR5
MREwDwYDVQQKDAhUb2l0VGVzdDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI1MDQx
NDA4MzAxM1oYDzIxMjUwMzIxMDgzMDEzWjBTMQswCQYDVQQGEwJESzEOMAwGA1UE
CAwFU3RhdGUxDTALBgNVBAcMBENpdHkxETAPBgNVBAoMCFRvaXRUZXN0MRIwEAYD
VQQDDAlsb2NhbGhvc3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDf
boYvC/jUi+v68II6WB5b52ygexqELW7wgFYYE5At/IqDEGKJuF7KAawtp0TgmUx0
IdKu98Ro6ZPxhhjvsix5Hqkn1Aj4DFpDPQ5ldY7dOhT/tLshFWHHxSXUlPDFt9Z/
l4W+ENgS9ix+IiH6Ar7YK4AoOWG9KWW/GOSa6cXbf6+yl3JPP3D6mtgALPpVDo4H
dyuE+S6mZyHPt8QTAna2ERQPBWz34obiYre+XLDwZTQ7FlAeh2hVgECuuKyOGQx+
mQuD246T2ptLN01fthZ7P+mQzAC2d2gJZ1T82WPpzc+T4/uZTxFZpDNhZuTO6c1S
zeIFGTYDFF+nY1rw80G5AgMBAAGjUzBRMB0GA1UdDgQWBBRR/4wWjhedHG+FsatA
mKWsmkuQbzAfBgNVHSMEGDAWgBRR/4wWjhedHG+FsatAmKWsmkuQbzAPBgNVHRMB
Af8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQCrGjxeHVXHrjQUtqC98Dzd759c
qpyVZ2zvwFYDpG8T69lM8EpB7T8KlTtN9KQY1icbbjGcxLaSr0zgDVFjMcnBDw5O
38f6pn9NNv8hthbQNvW5aLoQcd2ZLAt+3T5OEPfxncWr6jmQ37NME2fgRsYQrrpW
yDZyl3Rx27BLRO2+Rx48hnJOPNwB2FXKR5NqBvMsOgq58GzmI+MQN6X90Sb72lym
TVIvByko9iN46XPtctS/GKSYbE4b6gXcjQ+O/uMxFZTr7g9dWlDiH2XK1p0GkUao
l9oWaa9ZIMhXPkfOvkT1Mm95KiM15/LyomIzS9lemCdhWBB1OyvXsAQ+126Q
-----END CERTIFICATE-----
"""

SERVER-KEY ::= """
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDfboYvC/jUi+v6
8II6WB5b52ygexqELW7wgFYYE5At/IqDEGKJuF7KAawtp0TgmUx0IdKu98Ro6ZPx
hhjvsix5Hqkn1Aj4DFpDPQ5ldY7dOhT/tLshFWHHxSXUlPDFt9Z/l4W+ENgS9ix+
IiH6Ar7YK4AoOWG9KWW/GOSa6cXbf6+yl3JPP3D6mtgALPpVDo4HdyuE+S6mZyHP
t8QTAna2ERQPBWz34obiYre+XLDwZTQ7FlAeh2hVgECuuKyOGQx+mQuD246T2ptL
N01fthZ7P+mQzAC2d2gJZ1T82WPpzc+T4/uZTxFZpDNhZuTO6c1SzeIFGTYDFF+n
Y1rw80G5AgMBAAECgf8IBtkJJKWoGUrnJVDU+o6XsL9xa61a8bjP1gTR2pfYxUNZ
h3cbyH0atnDmNorg4Z/M16qFk+xsi9fk7TCe2DFgYB2gijhEGWSs4TIX5O1IF/lX
yTZBKT4HeoxHxj4ShcwV6xm7n0s/TbVPDw4uL9J0lSj7kMsjtr0IbkLoWIeP8eZ2
67XIfvnAho9YEndCpqt7YbhbzXO+kFR09eJLMTqE+WRSYGkazVh53Ibkls3P4UsE
8qWel59XxZj/zjbSmXrV73X/UwMZWZvd7GcUO0ICMCAWgW4B7Xht7swo7GgxiERo
fdZTd5C2NGqe4PDd8aprTo7LuDls0xnfzchhpAECgYEA/++XG1bc8rMz/AqgQLKn
rHoHUNIA1BjC6p2qBl4UXRPN8p4vRww67fPYtkoSRp2u4fXW4NT3l+OrvHKkRjYD
AB1iAneGIPQ2UuKP1SCZ2y0Y/U6dGg8/J8U2JzZH7iIcLA8gkdRmmTwtki3Vx6ta
PkjSllYdUyh2AHQRzNmFWRkCgYEA33zZjvwkdegwFZ5NZjHVfXCkA5a9fh+VM2Iz
z7RRXPQ5V9JA0DzHg2wvbQ98ipKeNQGxa34RwRMAxGRBbUjcFfkAbgFwZWFBsKI1
oZBfPYOkDyFYCLRyoOwxo0F5kWGM/im68WSHzfAp/3AZFxmEGQpbWrFcNiEygmIH
CTGqIaECgYEAktoCtiktNgUlOuVN9lGMbCbIs9MLrqdWkBBPUsAApzeJ4EBrmDSo
S4izPEVcHzCy++x3kyIfvwNfsw2EvNSY/CPf7NJwH9CAqyZcqUm/fkduI0pMUnuV
HVjHLdCzjSv9RjqX0ZUyGZKyA0JRe/QSH9LhImnfAawhqTjwTb4yCWECgYEAytfL
sx6hjS7H7ec3guj6R5dkFinMJdxOlEuukPet3XuBTHd2AksYHu2jgg5LUI7Q73Vw
7gqH3MD9skL4q1M1BvBw9mdx92I1uDcSDGk4OGHyFxWBjK0TWYHnb7DuwQhUax+/
IHfJVx6DT+gTrcaoAf5HemJ+OlcZPAPzNOIR8+ECgYEA6jtHv3IOmBuiSwSdE9Dz
e284uJmUrzb9HI2VI9nmNsJ4cWRucqzzdPrcG7pemG5+goMcTA28EMhA1SXZhg3D
PdJtvTZsQgmyMXy3bc/9r88rqAtPhpTZTo+yyaPnOWZOWJR7sGuKXuLeZ3BAlnmg
ciw7wDd945w/LNWcsVRPsLM=
-----END PRIVATE KEY-----
"""
