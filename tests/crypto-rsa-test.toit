// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import crypto.rsa
import crypto.sha
import crypto.sha1
import expect show *

// Non-production test vector. 2048-bit RSA key.
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
  test-rsa
  test-sha1
  test-digest-length

test-rsa:
  priv := rsa.RsaKey.parse-private PRIVATE-KEY
  pub := rsa.RsaKey.parse-public PUBLIC-KEY

  msg := "Hello World"
  
  // Test 1: Sign (implicit SHA-256).
  sig := priv.sign msg
  expect-not-null sig
  expect sig.size > 0
  expect (pub.verify msg sig)

  // Test 2: Explicit Hash SHA-256.
  sig256 := priv.sign msg --hash=rsa.RsaKey.SHA-256
  is-valid := pub.verify msg sig256 --hash=rsa.RsaKey.SHA-256
  expect is-valid
  // Should also work implicitly.
  is-valid-implicit := pub.verify msg sig256
  expect is-valid-implicit

  // Test 3: Sign Digest.
  digest := sha.sha256 msg
  sig-digest := priv.sign-digest digest --hash=rsa.RsaKey.SHA-256
  is-valid-digest := pub.verify-digest digest sig-digest --hash=rsa.RsaKey.SHA-256
  expect is-valid-digest
  // Mixing APIs: Verify message against digest-signed signature.
  is-valid-mixed := pub.verify msg sig-digest
  expect is-valid-mixed

  // Test 4: Tampering.
  bad-msg := "Hello world" // Lower case.
  is-valid-bad := pub.verify bad-msg sig
  expect-not is-valid-bad
  
  sig[0] ^= 0xFF
  is-valid-tampered := pub.verify msg sig
  expect-not is-valid-tampered

test-sha1:
  priv := rsa.RsaKey.parse-private PRIVATE-KEY
  pub := rsa.RsaKey.parse-public PUBLIC-KEY

  msg := "Legacy Message"
  
  // Sign with SHA-1.
  sig := priv.sign msg --hash=rsa.RsaKey.SHA-1
  is-valid := pub.verify msg sig --hash=rsa.RsaKey.SHA-1
  expect is-valid
  
  // Implicit verification should FAIL (defaults to SHA-256).
  is-valid-implicit := pub.verify msg sig
  expect-not is-valid-implicit

  // Explicit verification with wrong hash should FAIL.
  is-valid-wrong := pub.verify msg sig --hash=rsa.RsaKey.SHA-256
  expect-not is-valid-wrong

test-digest-length:
  priv := rsa.RsaKey.parse-private PRIVATE-KEY
  
  msg := "Message"
  digest256 := sha.sha256 msg
  digest1 := sha1.sha1 msg

  // Pass SHA-1 digest but say it's SHA-256 -> Should Throw.
  expect-throw "INVALID_ARGUMENT":
    priv.sign-digest digest1 --hash=rsa.RsaKey.SHA-256
  
  // Pass SHA-256 digest but say it's SHA-1 -> Should Throw.
  expect-throw "INVALID_ARGUMENT":
    priv.sign-digest digest256 --hash=rsa.RsaKey.SHA-1
  
  // Pass correct length.
  priv.sign-digest digest256 --hash=rsa.RsaKey.SHA-256
  priv.sign-digest digest1 --hash=rsa.RsaKey.SHA-1

  print "RSA Tests Passed"
