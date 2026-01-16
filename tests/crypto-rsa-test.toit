// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import crypto.rsa
import crypto.sha
import expect show *

// 2048-bit RSA key
PRIVATE-KEY ::= """
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDeCi2zVJ3mbsp7
HDwPvmSWdeoHP4hmAw0cYFHNA7dePfw/wD1bN1bjQXyZmuLEot0JfsFBwyMtR0/E
JCZqrygFi45Y4glh5a2nF8TJtZh7OgR/F7pmybnPUyFvGbgAGbb8oxOFX2Q3cee2
TDysRhYZznc17CuxuegbRmSJtuv6HD9GD8ayW7fjnOBaUExaaf3rDjTyUxo71wPW
D7btNrF/W/YlADtWXZZqd38TCbWMjZ0Yql/B1vk066SsFVU/MnO0jZ4Z1dTjByD2
gKQ4mcfKj9HjV4325Ba3O0mQH8uXGln/lJE9Zf6kJ2TmnXzB1m26ErFRM87zz0Lj
zGjabjrpAgMBAAECggEAIOhfR5HF6S4IYmCX4jl0jPwi2DopS/0tx0PbO8hON/B1
3zjtnwQ/o2TEQ7u52izNF6gqmkWChCZqgwZcjzkwdEnvqequO00gBIC4ULDSTYkW
u4NXw/4nxLtsXBvyskkdXqoIrZ6qqrD+B32bDGlCw0ZfUqWTAD8uUESJiAONS773
O1FWTIp0ZvzxcP+uIXIrLCWVykRYY1QbhkLbne4yg31LQSkHlZTdx7sIVCmjfnc7
s1bU0ZPBRV7r6SYpbYOhyw5TcyHzJwVkoRn4t4T3NmP6OkJDJR+2pTo+LVuxE7GG
0ThSe6wDsZLDqq6T4x2Q4d4usqG3qvJZuM/2JYW9UQKBgQD6q+ld12VoCJzGt049
19oGtHhNQH4ACem6GVjhES9UbKiyU/8/dXUaSer6XrFGrU0K77Tg6SdN8EM1Xw4G
gUupkSwCA30S0GDeFK+VZ4gttypoWbbfrvIjQdZcuG0xHUUaJZfI6ZYqds3g71XJ
VSEeR6q5hPKSOPc69Pt/N43SBQKBgQDiwnXbpAq2m4ZmtFjsj0IebFvsLdy6eiFm
CMTOuPQIWGsHV8G8Ni+IQwBusRP+l0euy1pvu8IR3taGVaUq2laqH5UzyGZ0t63V
s2MaiEfZt5d5ImcpEMIsQhuJx33uivLjDqTWxVebhY11KxBj3NfI3Ap+PzXsJAgq
o9ciQ3FmlQKBgGPbNcSfOJM/0wxKG04BfaXsIHxNs6PaTxRGYqSNzvfnrTAUy/qA
lNybE5MXQ7Fu+eDgaoKp/nFKw8swCYtH2Fc9MHXA5AMppVzyipuOua3UaH1XN8VV
kLnA0V7wTPcivNNUpGlxu9NArnTrgpYIZoAEdpseve7H6JzA2Krt+33tAoGALpbX
kjYFAXm4xnc9YfUZF5kZ1c+ibynSnN0mWnbDpMdNzidopZvYbj2d5CA7xG4eizo6
rYQ9HmDTYKxOEBzl+3QbupTtAAQREjwWG4hugrvmwjugSF6qFl/KuqcjJ5SizKXg
lkPbeReadb1QU8Q3DYywFzozgP3yM5iQBfknXnUCgYEA57+2D4u7+/tBW3Tbf9nw
1fglk+ySF9xIzVSSpwyB7a7KdXfIyk45zpvXT517rhsRf/Zu4svsAClwOSeIwnAD
qnvYtI4NYKEzSjdEhfGP9YZM/DjBBmByH/AoP/gomee84ucYBti+uyMbcsmsIyXI
pQLOIVhpDjidXYEl4WiWhZU=
-----END PRIVATE KEY-----
"""

PUBLIC-KEY ::= """
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA3gots1Sd5m7Kexw8D75k
lnXqBz+IZgMNHGBRzQO3Xj38P8A9WzdW40F8mZrixKLdCX7BQcMjLUdPxCQmaq8o
BYuOWOIJYeWtpxfEybWYezoEfxe6Zsm5z1Mhbxm4ABm2/KMThV9kN3Hntkw8rEYW
Gc53NewrsbnoG0Zkibbr+hw/Rg/Gslu345zgWlBMWmn96w408lMaO9cD1g+27Tax
f1v2JQA7Vl2Wand/Ewm1jI2dGKpfwdb5NOukrBVVPzJztI2eGdXU4wcg9oCkOJnH
yo/R41eN9uQWtztJkB/LlxpZ/5SRPWX+pCdk5p18wdZtuhKxUTPO889C48xo2m46
6QIDAQAB
-----END PUBLIC KEY-----
"""

main:
  test_rsa

test_rsa:
  priv := rsa.RsaKey.parse_private_key PRIVATE-KEY.to_byte_array
  pub := rsa.RsaKey.parse_public_key PUBLIC-KEY.to_byte_array

  msg := "Hello World"
  digest := sha.sha256 msg
  
  // Sign
  sig := priv.sign digest
  expect-not-null sig
  expect (sig.size > 0)

  // Verify
  valid := pub.verify digest sig
  expect valid

  // Tamper with digest
  bad_digest := sha.sha256 "Hello world" // case difference
  expect-not (pub.verify bad_digest sig)

  // Tamper with signature
  sig[0] ^= 0xFF
  expect-not (pub.verify digest sig)
  sig[0] ^= 0xFF // restore

  // Test with byte arrays
  priv_bytes := rsa.RsaKey.parse_private_key (PRIVATE-KEY.to_byte_array)
  pub_bytes := rsa.RsaKey.parse_public_key (PUBLIC-KEY.to_byte_array)
  
  sig2 := priv_bytes.sign digest
  expect (pub_bytes.verify digest sig2)

  print "RSA Tests Passed"

