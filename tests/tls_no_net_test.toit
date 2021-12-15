// Copyright (C) 2020 Toitware ApS. All rights reserved.

import tls
import tls.session as tls
import net.x509 as net
import reader

PACKS := 20
SIZE := 1024
TOTAL := PACKS * SIZE

main:
  s1 := Socket
  s2 := Socket

  s1.peer_ = s2
  s2.peer_ = s1

  s := tls.Session.server s1 s1
    --root_certificates=[TEST_ROOT_CERT]
    --certificate=tls.Certificate TEST_LOCALHOST_CERT_DIRECTLY_SIGNED TEST_LOCALHOST_KEY_DIRECTLY_SIGNED
  task::
    i := 0
    while i < TOTAL:
      b := s.read
      s.write b
      i += b.size

  c := tls.Session.client s2 s2
    --root_certificates=[TEST_ROOT_CERT]
    --certificate=tls.Certificate TEST_CLIENT_CERT_DIRECTLY_SIGNED TEST_CLIENT_KEY_DIRECTLY_SIGNED

  task::
    b := ByteArray SIZE
    c.write b

  i := 0
  while i < TOTAL:
    b := c.read
    c.write b
    i += b.size

monitor Socket implements reader.Reader:
  peer_ := null
  queue_ := []

  put data:
    queue_.add data

  write data from=0 to=data.size:
    peer_.put
      data.copy from to
    return to - from

  read:
    await: not queue_.is_empty
    l := queue_.first
    for i := 0; i < queue_.size - 1; i++:
      queue_[i] = queue_[i + 1]
    queue_.resize queue_.size - 1
    return l

// "Private" testing key.  This is a private key signed directly by
// the test CA root.  Uses the secp384r1 curve.
TEST_LOCALHOST_KEY_DIRECTLY_SIGNED ::= """\
-----BEGIN EC PARAMETERS-----
BgUrgQQAIg==
-----END EC PARAMETERS-----
-----BEGIN EC PRIVATE KEY-----
MIGkAgEBBDDAcESWjWBlB8E0fQZQ5NPZRSPNZqNQWzH4CDFO3mSEgBVOdHes6k7C
xklS25//dnqgBwYFK4EEACKhZANiAAQQdt5cWr2z78dv8B7AbG4/yMI+jmvKp0tM
8DCsKFA+I6mlUsPs0a/ujqX47WcJsScjNt3Rpmherru5UHnMRzj5352TgE1lhmdE
ZcqXiThVrKOEZg2Lxs/StYugs3xVyk0=
-----END EC PRIVATE KEY-----"""

// Public testing cert.  This is a cert for "localhost" signed
// directly by the trusted root (there's no non-trivial chain).
// Valid until Oct 25 2046.  Serial number
// d2:3f:60:08:69:ff:db:b3:02:df:1d:fb:90:d1:13:7a (localhost)
// Uses the secp384r1 curve.
TEST_LOCALHOST_CERT_DIRECTLY_SIGNED ::= net.Certificate.parse """\
-----BEGIN CERTIFICATE-----
MIICMjCCAbegAwIBAgIRANI/YAhp/9uzAt8d+5DRE3owCgYIKoZIzj0EAwIwVzEL
MAkGA1UEBhMCREsxETAPBgNVBAoMCFRvaXR3YXJlMRUwEwYDVQQLDAxUZXN0IFJv
b3QgQ0ExHjAcBgNVBAMMFVRvaXR3YXJlIFRlc3QgUm9vdCBDQTAeFw0yMTEwMDYx
MzIyMTFaFw00NjEwMjUxMzIyMTFaMDsxCzAJBgNVBAYTAkRLMRgwFgYDVQQKDA9M
b2NhbGhvc3QgT3duZXIxEjAQBgNVBAMMCWxvY2FsaG9zdDB2MBAGByqGSM49AgEG
BSuBBAAiA2IABBB23lxavbPvx2/wHsBsbj/Iwj6Oa8qnS0zwMKwoUD4jqaVSw+zR
r+6OpfjtZwmxJyM23dGmaF6uu7lQecxHOPnfnZOATWWGZ0RlypeJOFWso4RmDYvG
z9K1i6CzfFXKTaNjMGEwCQYDVR0TBAIwADAdBgNVHQ4EFgQUYbBQbTUo1O4gcOr6
gpOyIMaujnswHwYDVR0jBBgwFoAUswPsq/UZFMf8Z9TpXfLIvIvit+IwFAYDVR0R
BA0wC4IJbG9jYWxob3N0MAoGCCqGSM49BAMCA2kAMGYCMQDkofJBA00OhUecSsjS
Uq88oqpJB5hc2gYPIn6ClkJ/0fSfdwnW79nsXR88TgmQpVMCMQDbDPzSj97e3ir0
Ov8WPwNpToYAlB6wWUXbamEINGfq2GPwg+8PECg3gJbZ/Im4Vco=
-----END CERTIFICATE-----"""

// Trusted test CA root that has signed the intermediate cert and the directly
// signed localhost cert. Valid until 2221.  Uses the secp384r1 curve.
// Serial 0d:dc:a1:43:7d:65:d7:e8:91:4a:ae:10:2e:62:be:60:ba:ee:fe:3b
TEST_ROOT_CERT ::= net.Certificate.parse """\
-----BEGIN CERTIFICATE-----
MIICQjCCAcigAwIBAgIUDdyhQ31l1+iRSq4QLmK+YLru/jswCgYIKoZIzj0EAwIw
VzELMAkGA1UEBhMCREsxETAPBgNVBAoMCFRvaXR3YXJlMRUwEwYDVQQLDAxUZXN0
IFJvb3QgQ0ExHjAcBgNVBAMMFVRvaXR3YXJlIFRlc3QgUm9vdCBDQTAgFw0yMTEw
MDYxMzIyMTFaGA8yMjIxMDgxOTEzMjIxMVowVzELMAkGA1UEBhMCREsxETAPBgNV
BAoMCFRvaXR3YXJlMRUwEwYDVQQLDAxUZXN0IFJvb3QgQ0ExHjAcBgNVBAMMFVRv
aXR3YXJlIFRlc3QgUm9vdCBDQTB2MBAGByqGSM49AgEGBSuBBAAiA2IABIvCQ6eF
SWk5aM7nhl5TFU2mMSIZHUBxwuhCYMWO+tdZdGAYfkBX+8uhRwcTJTugh8Duexer
ItU32QrlHg+doIBrxbSLL+B1yHAAa0Q9UN/zKGyr58ANCKrN55x0aclpWqNTMFEw
HQYDVR0OBBYEFLMD7Kv1GRTH/GfU6V3yyLyL4rfiMB8GA1UdIwQYMBaAFLMD7Kv1
GRTH/GfU6V3yyLyL4rfiMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDaAAw
ZQIwd6IXFPhbZEq4K9n4FpBpUjBB+6JRZwBpUtOYlufKawQv06jLdBp+hVJGx8Hc
nbfZAjEAhm5O1+WZUYXNXxgUO1LTzdo3ceNIW0nOrU6VYg6c5olPojD8tlbBISvO
HtNDoMEE
-----END CERTIFICATE-----"""

TEST_CLIENT_CERT_DIRECTLY_SIGNED ::= net.Certificate.parse """\
-----BEGIN CERTIFICATE-----
MIICWDCCAd6gAwIBAgIQfgIPOmVIp8dc8uEfUbjakDAKBggqhkjOPQQDAjBXMQsw
CQYDVQQGEwJESzERMA8GA1UECgwIVG9pdHdhcmUxFTATBgNVBAsMDFRlc3QgUm9v
dCBDQTEeMBwGA1UEAwwVVG9pdHdhcmUgVGVzdCBSb290IENBMB4XDTIxMTAwNjEz
MjMzNFoXDTQ2MTAyNTEzMjMzNFowSzELMAkGA1UEBhMCREsxEDAOBgNVBAoMB0Ns
aWVudHMxKjAoBgNVBAMMIWNsaWVudC0wMDAwMDAwMS50ZXN0LnRvaXR3YXJlLmNv
bTB2MBAGByqGSM49AgEGBSuBBAAiA2IABINnzsdzNTGoVPd15zG4//PR+L7fJk2E
lUmyRaN97xaHbY36Bigau1IWveEQ6nK6fFKQgByynnxSaGBNG+M0HLycvY/QB26+
U3tFkN+Ptv+f5wPwoCZ8JGLoOWOXvmc+KqN7MHkwCQYDVR0TBAIwADAdBgNVHQ4E
FgQUkG0Z3saGx48Clsh2qr0VBCXxsf8wHwYDVR0jBBgwFoAUswPsq/UZFMf8Z9Tp
XfLIvIvit+IwLAYDVR0RBCUwI4IhY2xpZW50LTAwMDAwMDAxLnRlc3QudG9pdHdh
cmUuY29tMAoGCCqGSM49BAMCA2gAMGUCMBBYIY2DGn3yTy3L8qo8wip1AAxZus0H
0nbgIs2vNEXoR5QEPffSN9hajy5XGx97KwIxAO9o6I1/0Zy9hpJNgvIEkynQQ6Ka
s9it46UU4HsqjqMnjzMDmPgJxMvUtei8ffbrPg==
-----END CERTIFICATE-----"""

TEST_CLIENT_KEY_DIRECTLY_SIGNED ::= """\
-----BEGIN EC PARAMETERS-----
BgUrgQQAIg==
-----END EC PARAMETERS-----
-----BEGIN EC PRIVATE KEY-----
MIGkAgEBBDAQ3bsSGOPRS3wyGb5O23g9/MISB3dcIMq3DLC7rwgiNl3bdPSPqJlM
CzPkOOiJQZ6gBwYFK4EEACKhZANiAASDZ87HczUxqFT3decxuP/z0fi+3yZNhJVJ
skWjfe8Wh22N+gYoGrtSFr3hEOpyunxSkIAcsp58UmhgTRvjNBy8nL2P0AduvlN7
RZDfj7b/n+cD8KAmfCRi6Dljl75nPio=
-----END EC PRIVATE KEY-----"""
