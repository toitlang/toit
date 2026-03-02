// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.
import crypto.rsa
import expect show *

main:
  print "Generating RSA key pair (2048 bits)..."
  key := rsa.RsaKey.generate --bits=2048
  print "Key generated."

  print "Exporting keys..."
  priv := key.private-key
  pub := key.public-key
  print "Private key size: $priv.size"
  print "Public key size: $pub.size"

  print "Signing message..."
  message := "Hello, Toit RSA!"
  signature := key.sign message
  print "Signature size: $signature.size"

  print "Verifying signature with original key..."
  expect (key.verify message signature)

  print "Parsing exported public key..."
  pub-key := rsa.RsaKey.parse-public pub.der
  expect (pub-key.verify message signature)

  print "Parsing exported private key..."
  priv-key := rsa.RsaKey.parse-private priv.der
  signature2 := priv-key.sign message
  expect (pub-key.verify message signature2)

  print "Testing encryption/decryption..."
  original-token := "MySecretToken123"
  encrypted := pub-key.encrypt original-token.to-byte-array
  decrypted := priv-key.decrypt encrypted
  expect-equals original-token decrypted.to-string

  print "Testing encryption/decryption (OAEP SHA256)..."
  oaep-encrypted := pub-key.encrypt original-token.to-byte-array --padding=rsa.RsaKey.PADDING-OAEP-V21 --hash=rsa.RsaKey.SHA-256
  oaep-decrypted := priv-key.decrypt oaep-encrypted --padding=rsa.RsaKey.PADDING-OAEP-V21 --hash=rsa.RsaKey.SHA-256
  expect-equals original-token oaep-decrypted.to-string

  print "All tests passed!"
